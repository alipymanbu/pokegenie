module Admission
  # Control plane / data plane separation (Principle III):
  # reads the admission batch size written by the (deferred) coordinator. If the key is
  # absent, unreadable, or non-positive, falls back to the safe default. NEVER raises —
  # the admission worker must keep running even if Redis or the coordinator misbehaves.
  class Pacing
    def self.batch_size(raid_id)
      QueueRedis.with do |r|
        raw = r.get(QueueConfig.admission_rate_key(raid_id))
        value = raw.to_i
        value.positive? ? value : QueueConfig::ADMISSION_DEFAULT_BATCH
      end
    rescue => e
      Rails.logger.warn("[admission] pacing read failed, using default batch: #{e.class}: #{e.message}")
      QueueConfig::ADMISSION_DEFAULT_BATCH
    end
  end
end
