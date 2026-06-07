require "securerandom"

module Encounters
  # Join an Encounter's single FIFO line (not a specific room). Mirrors RaidQueue::Join:
  # strict FIFO via an INCR sequence, idempotent re-join, presence-based reconnect grace.
  class Join
    def self.call(encounter:, trainer:)
      new(encounter:, trainer:).call
    end

    def initialize(encounter:, trainer:)
      @encounter = encounter
      @trainer = trainer
    end

    def call
      return ServiceResult.failure(code: :not_published) unless @encounter.published?

      QueueRedis.with do |r|
        member = @trainer.id.to_s
        qkey = QueueConfig.enc_queue_key(@encounter.id)
        existing = r.zscore(qkey, member)
        present = r.exists?(QueueConfig.enc_presence_key(@encounter.id, member))

        if existing && !present # gone past grace → back of the line
          r.zrem(qkey, member)
          existing = nil
        end

        if existing.nil?
          score = r.incr(QueueConfig.enc_seq_key(@encounter.id))
          r.zadd(qkey, score, member, nx: true)
        end

        touch_presence(r, member)
        token = mint_token(r, member)
        ServiceResult.success(
          token: token, state: "waiting",
          position: r.zrank(qkey, member)&.+(1), depth: r.zcard(qkey)
        )
      end
    end

    private

    def touch_presence(redis, member)
      redis.set(QueueConfig.enc_presence_key(@encounter.id, member), "1", ex: QueueConfig::RECONNECT_GRACE_SECONDS)
    end

    def mint_token(redis, member)
      token = SecureRandom.urlsafe_base64(24)
      payload = {
        encounter_id: @encounter.id, trainer_id: @trainer.id,
        score: redis.zscore(QueueConfig.enc_queue_key(@encounter.id), member),
        joined_at: Time.now.utc.iso8601
      }.to_json
      redis.set(QueueConfig.token_key(token), payload, ex: QueueConfig::RECONNECT_GRACE_SECONDS)
      token
    end
  end
end
