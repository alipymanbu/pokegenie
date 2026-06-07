module Encounters
  # Resolve a trainer's state in an encounter:
  #   waiting  → still in the FIFO line (1-based position + depth)
  #   admitted → assigned to a room, may claim (returns room_id/room_number + seconds left)
  #   reserved → already holds a confirmed reservation in one of the encounter's rooms
  #   gone     → none of the above (left / expired)
  class Position
    def self.call(encounter:, trainer_id:)
      new(encounter:, trainer_id:).call
    end

    def initialize(encounter:, trainer_id:)
      @encounter = encounter
      @trainer_id = trainer_id.to_s
    end

    def call
      QueueRedis.with do |r|
        rank = r.zrank(QueueConfig.enc_queue_key(@encounter.id), @trainer_id)
        return waiting(r, rank) if rank

        room_id = r.get(QueueConfig.enc_assignment_key(@encounter.id, @trainer_id))
        ttl = room_id ? r.ttl(QueueConfig.claimable_key(room_id, @trainer_id)) : -2
        return admitted(room_id, ttl) if room_id && ttl.positive?

        reservation = existing_reservation
        return reserved(reservation) if reservation

        ServiceResult.failure(code: :gone)
      end
    end

    private

    def waiting(redis, rank)
      ServiceResult.success(state: "waiting", position: rank + 1,
                            depth: redis.zcard(QueueConfig.enc_queue_key(@encounter.id)))
    end

    def admitted(room_id, ttl)
      room = Raid.find_by(id: room_id)
      ServiceResult.success(state: "admitted", room_id: room_id.to_i,
                            room_number: room&.room_number, claim_seconds_remaining: ttl)
    end

    def reserved(reservation)
      ServiceResult.success(state: "reserved", room_id: reservation.raid_id,
                            room_number: reservation.raid.room_number)
    end

    def existing_reservation
      Reservation.joins(:raid).find_by(raids: { encounter_id: @encounter.id }, trainer_id: @trainer_id)
    end
  end
end
