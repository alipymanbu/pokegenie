module RaidQueue
  # Resume a trainer's session from their reconnect token (FR-010/011/014).
  #
  # Token valid (within grace): refresh presence + token TTL, restore the queue entry at its
  # ORIGINAL score if it was dropped, and report current state — including any reservation the
  # trainer already holds (which lives in Postgres and survives disconnects, FR-011).
  #
  # Token missing/expired: failure(:expired) — the caller treats the trainer as a new arrival
  # (a fresh Join, which places them at the back of the line, FR-014).
  class Reconnect
    def self.call(raid:, token:)
      new(raid:, token:).call
    end

    def initialize(raid:, token:)
      @raid = raid
      @token = token
    end

    def call
      payload = QueueRedis.with { |r| r.get(QueueConfig.token_key(@token)) }
      return ServiceResult.failure(code: :expired) if payload.blank?

      data = JSON.parse(payload)
      trainer = Trainer.find_by(id: data["trainer_id"])
      return ServiceResult.failure(code: :expired) unless trainer

      reservation = Reservation.find_by(raid_id: @raid.id, trainer_id: trainer.id)
      restore_and_heartbeat(trainer, data["score"], reservation)

      pos = RaidQueue::Position.call(raid_id: @raid.id, trainer_id: trainer.id)
      ServiceResult.success(
        token: @token,
        trainer_handle: trainer.handle,
        reservation: reservation,
        state: reservation ? "reserved" : (pos.ok? ? pos.data[:state] : "gone"),
        position: pos.ok? ? pos.data[:position] : nil,
        depth: pos.ok? ? pos.data[:depth] : 0,
        claim_seconds_remaining: pos.ok? ? pos.data[:claim_seconds_remaining] : nil
      )
    end

    private

    def restore_and_heartbeat(trainer, score, reservation)
      member = trainer.id.to_s
      QueueRedis.with do |r|
        still_queued = !r.zscore(QueueConfig.queue_key(@raid.id), member).nil?
        admitted = r.exists?(QueueConfig.claimable_key(@raid.id, member))
        # If they were dropped from the line but are reconnecting within grace and haven't been
        # admitted or reserved, put them back at their original score.
        if !still_queued && !admitted && reservation.nil? && score
          r.zadd(QueueConfig.queue_key(@raid.id), score, member, nx: true)
        end
        r.set(QueueConfig.presence_key(@raid.id, member), "1", ex: QueueConfig::RECONNECT_GRACE_SECONDS)
        r.expire(QueueConfig.token_key(@token), QueueConfig::RECONNECT_GRACE_SECONDS)
      end
    end
  end
end
