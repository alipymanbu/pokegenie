module Encounters
  # Elastic admission with AFK-slot backfill (FE-002, feature 002 + backfill).
  #
  # Pops the next batch from the encounter's FIFO line and assigns each trainer to the earliest
  # room with a free slot, spawning a new room only when none has room. "Free" accounts for
  # confirmed claims AND outstanding holds; a hold that lapses (admitted trainer never claimed)
  # is pruned, so its slot is BACKFILLED to a later trainer instead of being wasted.
  #
  # Only the single admission worker runs this, so room selection/spawning is race-free; the
  # per-room atomic claim still guarantees no oversell even if a hold/claim momentarily race.
  class AdmitBatch
    def self.call(encounter:)
      new(encounter:).call
    end

    def initialize(encounter:)
      @encounter = encounter
      @size = encounter.room_size
    end

    def call
      members = QueueRedis.with { |r| Array(r.zpopmin(QueueConfig.enc_queue_key(@encounter.id), batch_size)) }
      return { admitted: 0, rooms_spawned: 0, backfilled: 0 } if members.empty?

      now = Time.now.to_i
      # [room, free_slots] for existing rooms, earliest first (so freed early-room slots fill first).
      rooms = @encounter.rooms.order(:room_number).map { |room| [ room, free_slots(room, now) ] }
      spawned = 0
      backfilled = 0

      members.each do |member, _score|
        slot = rooms.find { |(_room, free)| free > 0 }
        if slot.nil?
          room = spawn_room
          slot = [ room, @size ]
          rooms << slot
          spawned += 1
        else
          # Reusing a room that already has confirmed/holds in it = a backfill into a freed slot.
          backfilled += 1 if slot[0].slots_remaining < @size
        end
        assign(member, slot[0], now)
        slot[1] -= 1
      end

      { admitted: members.size, rooms_spawned: spawned, backfilled: backfilled }
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

    # Open capacity = confirmed_remaining (slots_remaining) minus still-active holds.
    # Prunes lapsed holds (AFK no-shows) so their slots become available again (backfill).
    def free_slots(room, now)
      holds = QueueRedis.with do |r|
        r.zremrangebyscore(QueueConfig.room_holds_key(room.id), 0, now)
        r.zcard(QueueConfig.room_holds_key(room.id))
      end
      room.slots_remaining - holds
    end

    def spawn_room
      number = (@encounter.rooms.maximum(:room_number) || 0) + 1
      Raid.create!(
        encounter: @encounter, room_number: number,
        boss: @encounter.boss, gym_name: "#{@encounter.label} · Room ##{number}",
        starts_at: @encounter.starts_at, capacity: @size,
        slots_remaining: @size, status: "published"
      )
    end

    def assign(member, room, now)
      QueueRedis.with do |r|
        r.zadd(QueueConfig.room_holds_key(room.id), now + QueueConfig::CLAIM_WINDOW_SECONDS, member)
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
