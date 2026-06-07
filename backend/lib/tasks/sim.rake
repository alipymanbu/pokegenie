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

  desc "Wipe raids/reservations + Redis state for a clean run"
  task reset: :environment do
    require "redis"
    Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")).flushdb
    Reservation.delete_all
    Raid.delete_all
    puts "✓ reset: cleared raids, reservations, and Redis"
  end
end
