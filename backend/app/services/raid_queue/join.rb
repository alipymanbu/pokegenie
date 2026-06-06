require "securerandom"

module RaidQueue
  # Adds a trainer to a raid's FIFO line (Redis sorted set).
  #
  # Fairness (Principle I):
  #   - score = INCR seq:{raid} → strict, unique, total ordering.
  #   - ZADD ... NX → a re-join / double-tap never moves an existing waiter (idempotent join).
  #
  # Returns ServiceResult with { token, state, position, depth } on success,
  # or failure(:raid_full) / failure(:not_published).
  class Join
    def self.call(raid:, trainer:)
      new(raid:, trainer:).call
    end

    def initialize(raid:, trainer:)
      @raid = raid
      @trainer = trainer
    end

    def call
      return ServiceResult.failure(code: :not_published) unless @raid.published?
      return ServiceResult.failure(code: :raid_full) if @raid.full?

      QueueRedis.with do |r|
        member = @trainer.id.to_s
        existing_score = r.zscore(QueueConfig.queue_key(@raid.id), member)

        if existing_score.nil?
          score = r.incr(QueueConfig.seq_key(@raid.id))
          # NX guards the rare concurrent double-join: only the first sets the score.
          added = r.zadd(QueueConfig.queue_key(@raid.id), score, member, nx: true)
          score = r.zscore(QueueConfig.queue_key(@raid.id), member) unless added
        end

        token = mint_token(r, member)
        position = rank_to_position(r.zrank(QueueConfig.queue_key(@raid.id), member))
        depth = r.zcard(QueueConfig.queue_key(@raid.id))

        ServiceResult.success(token: token, state: "waiting", position: position, depth: depth)
      end
    end

    private

    # Mint (or refresh) a reconnect token bound to this trainer+raid+score.
    def mint_token(redis, member)
      token = SecureRandom.urlsafe_base64(24)
      score = redis.zscore(QueueConfig.queue_key(@raid.id), member)
      payload = {
        raid_id: @raid.id,
        trainer_id: @trainer.id,
        score: score,
        joined_at: Time.now.utc.iso8601
      }.to_json
      redis.set(QueueConfig.token_key(token), payload, ex: QueueConfig::RECONNECT_GRACE_SECONDS)
      token
    end

    def rank_to_position(rank)
      rank.nil? ? nil : rank + 1 # ZRANK is 0-based; display as 1-based
    end
  end
end
