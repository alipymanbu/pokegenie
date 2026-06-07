# Standalone admission worker logic (driven by the `admission:run` rake task, run as its own
# process / docker-compose service).
#
# Realizes control/data-plane separation (Principle III): this process paces admission but the
# API's claim path never depends on it. If this worker dies, reservations remain correct; only
# the flow of new admissions pauses until it restarts. If the (deferred) admission coordinator
# is absent, Admission::Pacing supplies a safe default batch — the loop keeps running.
module AdmissionLoop
  module_function

  def run
    tick = QueueConfig::ADMISSION_TICK_MS / 1000.0
    Rails.logger.info("[admission_loop] starting; tick=#{tick}s default_batch=#{QueueConfig::ADMISSION_DEFAULT_BATCH}")
    running = true
    Signal.trap("INT")  { running = false }
    Signal.trap("TERM") { running = false }

    while running
      tick_once
      sleep(tick)
    end

    Rails.logger.info("[admission_loop] stopped")
  end

  # One admission pass over all published raids. Extracted so it can be unit-tested without
  # the infinite loop.
  def tick_once
    # Standalone raids (feature 001) — skip rooms, which belong to encounters.
    Raid.where(status: "published", encounter_id: nil).find_each do |raid|
      result = RaidQueue::AdmitBatch.call(raid: raid)
      if result[:admitted].positive? || result[:drained].positive?
        Rails.logger.info("[admission_loop] raid=#{raid.id} admitted=#{result[:admitted]} drained=#{result[:drained]} remaining=#{raid.reload.slots_remaining}")
      end
    end

    # Elastic encounters (feature 002) — admit into auto-spawned rooms.
    Encounter.where(status: "published").find_each do |enc|
      result = Encounters::AdmitBatch.call(encounter: enc)
      if result[:admitted].positive?
        Rails.logger.info("[admission_loop] encounter=#{enc.id} admitted=#{result[:admitted]} rooms_spawned=#{result[:rooms_spawned]}")
      end
    end
  rescue => e
    # Never let one bad tick kill the loop.
    Rails.logger.error("[admission_loop] tick error: #{e.class}: #{e.message}")
  end
end
