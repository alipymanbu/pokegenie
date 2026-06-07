module Encounters
  # Elastic admission (FE-002): pop the next batch from the encounter's FIFO line and assign each
  # trainer to a room with space — spawning a new room of `room_size` whenever the open room is
  # full. No "encounter full": supply expands to meet demand.
  #
  # Only the single admission worker runs this, so room selection/spawning is race-free.
  class AdmitBatch
    def self.call(encounter:)
      new(encounter:).call
    end

    def initialize(encounter:)
      @encounter = encounter
    end

    def call
      members = QueueRedis.with { |r| Array(r.zpopmin(QueueConfig.enc_queue_key(@encounter.id), batch_size)) }
      return { admitted: 0, rooms_spawned: 0 } if members.empty?

      spawned = 0
      members.each do |member, _score|
        room, fresh = open_room_for_assignment
        spawned += 1 if fresh
        assign(member, room)
      end
      { admitted: members.size, rooms_spawned: spawned }
    end

    private

    def batch_size
      QueueRedis.with do |r|
        v = r.get(QueueConfig.enc_admission_rate_key(@encounter.id)).to_i
        v.positive? ? v : QueueConfig::ADMISSION_DEFAULT_BATCH
      end
    rescue StandardError
      QueueConfig::ADMISSION_DEFAULT_BATCH
    end

    # Returns [room, spawned_bool]. Reuses the open room until its assignment count hits
    # room_size, then spawns the next one.
    def open_room_for_assignment
      QueueRedis.with do |r|
        open_id = r.get(QueueConfig.enc_open_room_key(@encounter.id))
        if open_id
          assigned = r.get(QueueConfig.room_assigned_key(open_id)).to_i
          room = Raid.find_by(id: open_id)
          return [ room, false ] if room && assigned < @encounter.room_size
        end
        [ spawn_room, true ]
      end
    end

    def spawn_room
      number = (@encounter.rooms.maximum(:room_number) || 0) + 1
      room = Raid.create!(
        encounter: @encounter, room_number: number,
        boss: @encounter.boss, gym_name: "#{@encounter.label} · Room ##{number}",
        starts_at: @encounter.starts_at, capacity: @encounter.room_size,
        slots_remaining: @encounter.room_size, status: "published"
      )
      QueueRedis.with { |r| r.set(QueueConfig.enc_open_room_key(@encounter.id), room.id) }
      room
    end

    def assign(member, room)
      QueueRedis.with do |r|
        r.incr(QueueConfig.room_assigned_key(room.id))
        r.set(QueueConfig.enc_assignment_key(@encounter.id, member), room.id, ex: QueueConfig::CLAIM_WINDOW_SECONDS)
        r.set(QueueConfig.claimable_key(room.id, member), "1", ex: QueueConfig::CLAIM_WINDOW_SECONDS)
        r.incr(QueueConfig.enc_metric_admitted_key(@encounter.id))
        message = {
          event: "admitted", trainer_id: member.to_i,
          data: { encounter_id: @encounter.id, room_id: room.id, room_number: room.room_number,
                  claim_seconds_remaining: QueueConfig::CLAIM_WINDOW_SECONDS }
        }.to_json
        r.publish(QueueConfig.enc_events_channel(@encounter.id), message)
      end
    end
  end
end
