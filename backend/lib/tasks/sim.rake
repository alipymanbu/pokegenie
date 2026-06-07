# Convenience wrapper around sim/simulate.rb so you don't pass ENV vars by hand.
#
#   bundle exec rake sim:fast          # ~2000 trainers, default (fast) admission
#   bundle exec rake sim:queue_heavy   # deep, sustained lines (throttled admission)
#   bundle exec rake sim:reset         # wipe raids/reservations + Redis before a run
#   bundle exec rake "sim:run[fast]"   # explicit profile form
#
# Any SIM_* you set in the environment overrides the profile, e.g.
#   SIM_TRAINERS=500 bundle exec rake sim:queue_heavy
namespace :sim do
  PROFILES = {
    # Big, fast load — exercises throughput + the no-oversell invariant under contention.
    "fast" => {
      "SIM_TRAINERS" => "2000", "SIM_RAIDS" => "25", "SIM_DURATION" => "40",
      "SIM_SSE" => "20", "SIM_CONCURRENCY" => "200", "SIM_HOT_BIAS" => "0.6"
    },
    # Deep, sustained lines — raids never fill (high capacity), admission throttled via the
    # control-plane key, so trainers wait → reconnect/abandon/AFK fire. Watch /raids/:id/metrics.
    "queue_heavy" => {
      "SIM_TRAINERS" => "800", "SIM_RAIDS" => "6", "SIM_CAPACITY" => "400",
      "SIM_ADMISSION_RATE" => "2", "SIM_HOT_BIAS" => "0.3", "SIM_DURATION" => "30",
      "SIM_SSE" => "15", "SIM_CONCURRENCY" => "120"
    },
    # Elastic encounters — throttled admission so you can watch rooms spawn + backfill under load.
    # Watch /encounters/:id/metrics (per-room fill).
    "encounters" => {
      "SIM_MODE" => "encounters", "SIM_TRAINERS" => "600", "SIM_RAIDS" => "3",
      "SIM_CAPACITY" => "20", "SIM_ADMISSION_RATE" => "5", "SIM_HOT_BIAS" => "0.5",
      "SIM_DURATION" => "25", "SIM_SSE" => "15", "SIM_CONCURRENCY" => "150"
    }
  }.freeze

  def run_profile(name)
    preset = PROFILES.fetch(name) do
      abort "Unknown sim profile #{name.inspect}. Choose: #{PROFILES.keys.join(', ')}"
    end
    preset.each { |k, v| ENV[k] ||= v } # explicit ENV always wins over the profile
    shown = preset.keys.map { |k| "#{k.sub('SIM_', '')}=#{ENV[k]}" }.join(" ")
    puts "▶ sim profile: #{name}  [#{shown}]"
    puts "  Watch live: #{ENV.fetch('SIM_BASE', 'http://localhost:3002').sub('3002', '3003')} (operator view per raid)"
    load File.expand_path("../../sim/simulate.rb", __dir__)
  end

  desc "Run the load simulator with a named profile (default: fast). ENV vars override."
  task :run, [ :profile ] do |_t, args|
    run_profile(args[:profile] || ENV.fetch("SIM_PROFILE", "fast"))
  end

  desc "Fast/big load (~2000 trainers, default admission)"
  task(:fast) { run_profile("fast") }

  desc "Deep sustained queues (throttled admission; watch the operator view)"
  task(:queue_heavy) { run_profile("queue_heavy") }

  desc "Elastic encounters under load — watch rooms spawn + backfill (/encounters/:id/metrics)"
  task(:encounters) { run_profile("encounters") }

  desc "Pre-fill an encounter with N waiters + throttle it, so YOU can join behind the crowd"
  # Usage: bundle exec rake "sim:prefill[150,2]"   → 150 waiters, admit 2/tick (slow countdown)
  task :prefill, [ :count, :rate, :room_size ] => :environment do |_t, args|
    require "securerandom"
    count = (args[:count] || 150).to_i
    rate  = (args[:rate]  || 2).to_i
    size  = (args[:room_size] || 20).to_i

    # Throttle BEFORE publishing so the worker can't drain at the default batch; then publish and
    # enqueue. The in-process join loop finishes in well under one worker tick, so the queue stays
    # ~full. (Join requires a published encounter, hence publish-then-enqueue.)
    enc = Encounter.create!(boss: "Mewtwo", label: "Mega Raid Hour",
                            starts_at: 1.hour.from_now, room_size: size, status: "draft")
    QueueRedis.with { |r| r.set(QueueConfig.enc_admission_rate_key(enc.id), rate) }
    enc.update!(status: "published")
    count.times do |i|
      trainer = Trainer.find_or_create_by_handle!("waiter_#{i}_#{SecureRandom.hex(3)}")
      Encounters::Join.call(encounter: enc, trainer: trainer)
    end

    depth = QueueRedis.with { |r| r.zcard(QueueConfig.enc_queue_key(enc.id)) }
    puts "✓ Encounter ##{enc.id} prefilled: #{depth} waiters in line, admitting #{rate}/tick (~#{rate}/s)."
    puts "→ Join in the UI:  http://localhost:3003/encounters/#{enc.id}"
    puts "   You'll start around ##{depth + 1} and watch it count down. Operator view:"
    puts "   http://localhost:3003/encounters/#{enc.id}/metrics"
  end

  desc "Wipe raids/reservations + Redis state for a clean run"
  task reset: :environment do
    require "redis"
    Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")).flushdb
    Reservation.delete_all
    Raid.delete_all       # rooms (FK to encounters) must go before encounters
    Encounter.delete_all
    puts "✓ reset: cleared encounters, raids, reservations, and Redis"
  end
end
