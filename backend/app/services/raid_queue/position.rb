module RaidQueue
  # Resolves a trainer's current state in a raid's line:
  #   - waiting   → still in the sorted set; returns 1-based position + depth
  #   - admitted  → not in line but in the admitted set (may now claim)
  #   - gone      → neither (token expired / never joined / already claimed)
  class Position
    def self.call(raid_id:, trainer_id:)
      new(raid_id:, trainer_id:).call
    end

    def initialize(raid_id:, trainer_id:)
      @raid_id = raid_id
      @trainer_id = trainer_id.to_s
    end

    def call
      QueueRedis.with do |r|
        rank = r.zrank(QueueConfig.queue_key(@raid_id), @trainer_id)
        if rank
          ServiceResult.success(state: "waiting", position: rank + 1, depth: r.zcard(QueueConfig.queue_key(@raid_id)))
        else
          # Negative TTL means the key is gone (-2) or has no expiry (-1); either way, not claimable.
          ttl = r.ttl(QueueConfig.claimable_key(@raid_id, @trainer_id))
          if ttl.positive?
            ServiceResult.success(state: "admitted", position: nil, depth: r.zcard(QueueConfig.queue_key(@raid_id)), claim_seconds_remaining: ttl)
          else
            ServiceResult.failure(code: :gone)
          end
        end
      end
    end
  end
end
