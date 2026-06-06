module RaidQueue
  # Pops the next batch of waiting trainers from a raid's line and admits them, OR — if the
  # raid is already full — drains the remaining line with raid_full notifications.
  #
  # The batch size comes from Admission::Pacing (control plane), which falls back to a safe
  # default when the deferred coordinator is absent (Principle III). This service NEVER blocks
  # the claim hot path; capacity correctness lives entirely in Reservations::Claim.
  class AdmitBatch
    def self.call(raid:)
      new(raid:).call
    end

    def initialize(raid:)
      @raid = raid
    end

    def call
      @raid.reload
      return drain_full if @raid.full? || @raid.status == "closed"

      batch = Admission::Pacing.batch_size(@raid.id)
      members = QueueRedis.with { |r| Array(r.zpopmin(QueueConfig.queue_key(@raid.id), batch)) }
      return { admitted: 0, drained: 0 } if members.empty?

      ids = members.map { |member, _score| member }
      QueueRedis.with do |r|
        r.sadd(QueueConfig.admitted_key(@raid.id), ids)
        r.expire(QueueConfig.admitted_key(@raid.id), QueueConfig::CLAIM_WINDOW_SECONDS)
        r.incrby(QueueConfig.metric_admitted_key(@raid.id), ids.size)
      end
      ids.each { |id| publish(id, "admitted", claim_deadline: claim_deadline) }

      { admitted: ids.size, drained: 0 }
    end

    private

    # Raid is full: tell the rest of the line so they stop waiting (US1-AS1 losers).
    def drain_full
      members = QueueRedis.with { |r| Array(r.zpopmin(QueueConfig.queue_key(@raid.id), drain_chunk)) }
      members.each { |member, _score| publish(member, "raid_full") }
      { admitted: 0, drained: members.size }
    end

    def drain_chunk
      [ QueueConfig::ADMISSION_DEFAULT_BATCH, 200 ].max
    end

    def claim_deadline
      (Time.now.utc + QueueConfig::CLAIM_WINDOW_SECONDS).iso8601
    end

    def publish(trainer_id, event, **payload)
      data = { raid_id: @raid.id }.merge(payload)
      message = { event: event, data: data, trainer_id: trainer_id.to_i }.to_json
      QueueRedis.with { |r| r.publish(QueueConfig.events_channel(@raid.id), message) }
    end
  end
end
