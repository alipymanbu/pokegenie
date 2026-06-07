module Encounters
  # Resume an encounter session from a token (refresh-safe). Mirrors RaidQueue::Reconnect:
  # within grace → restore queue entry at original score + report current state; expired → :expired.
  class Reconnect
    def self.call(encounter:, token:)
      new(encounter:, token:).call
    end

    def initialize(encounter:, token:)
      @encounter = encounter
      @token = token
    end

    def call
      payload = QueueRedis.with { |r| r.get(QueueConfig.token_key(@token)) }
      return ServiceResult.failure(code: :expired) if payload.blank?

      data = JSON.parse(payload)
      trainer = Trainer.find_by(id: data["trainer_id"])
      return ServiceResult.failure(code: :expired) unless trainer

      restore_and_heartbeat(trainer, data["score"])
      pos = Encounters::Position.call(encounter: @encounter, trainer_id: trainer.id)

      ServiceResult.success(
        token: @token, trainer_handle: trainer.handle,
        state: pos.ok? ? pos.data[:state] : "gone",
        position: pos.ok? ? pos.data[:position] : nil,
        depth: pos.ok? ? pos.data[:depth] : 0,
        room_id: pos.ok? ? pos.data[:room_id] : nil,
        room_number: pos.ok? ? pos.data[:room_number] : nil,
        claim_seconds_remaining: pos.ok? ? pos.data[:claim_seconds_remaining] : nil
      )
    end

    private

    def restore_and_heartbeat(trainer, score)
      member = trainer.id.to_s
      QueueRedis.with do |r|
        queued = !r.zscore(QueueConfig.enc_queue_key(@encounter.id), member).nil?
        assigned = r.exists?(QueueConfig.enc_assignment_key(@encounter.id, member))
        reserved = Reservation.joins(:raid).exists?(raids: { encounter_id: @encounter.id }, trainer_id: trainer.id)
        if !queued && !assigned && !reserved && score
          r.zadd(QueueConfig.enc_queue_key(@encounter.id), score, member, nx: true)
        end
        r.set(QueueConfig.enc_presence_key(@encounter.id, member), "1", ex: QueueConfig::RECONNECT_GRACE_SECONDS)
        r.expire(QueueConfig.token_key(@token), QueueConfig::RECONNECT_GRACE_SECONDS)
      end
    end
  end
end
