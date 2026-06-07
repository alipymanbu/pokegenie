# frozen_string_literal: true

# Real-world load/behavior simulator for the PokeGenie Raid Queue.
#
# Spawns thousands of fiber-based "virtual trainers" (via the `async` gem) that drive the REAL
# HTTP API. Two modes:
#   SIM_MODE=raids       (default) — trainers queue for fixed-capacity raids (feature 001)
#   SIM_MODE=encounters             — trainers queue for an Encounter; the system auto-assigns a
#                                     room and SPAWNS new rooms on demand (feature 002, elastic)
#
# Run:  bundle exec ruby sim/simulate.rb     (or: bundle exec rake sim:fast | sim:queue_heavy | sim:encounters)
#
# Tunables (ENV): SIM_BASE SIM_TRAINERS SIM_RAIDS SIM_DURATION SIM_SSE SIM_CONCURRENCY
#   SIM_HOT_BIAS SIM_CAPACITY (raid capacity / encounter room_size) SIM_ADMISSION_RATE SIM_MODE

ENV["CONSOLE_LEVEL"] ||= "error"
Warning[:experimental] = false
$stdout.sync = true

require "async"
require "async/http/internet"
require "async/semaphore"
require "redis"
require "json"

BASE        = ENV.fetch("SIM_BASE", "http://localhost:3002")
TRAINERS    = ENV.fetch("SIM_TRAINERS", "2000").to_i
TARGETS_N   = ENV.fetch("SIM_RAIDS", "25").to_i
DURATION    = ENV.fetch("SIM_DURATION", "120").to_f
SSE_USERS   = ENV.fetch("SIM_SSE", "20").to_i
CONCURRENCY = ENV.fetch("SIM_CONCURRENCY", "200").to_i
HOT_BIAS    = ENV.fetch("SIM_HOT_BIAS", "0.6").to_f
CAPACITY    = ENV["SIM_CAPACITY"]&.to_i
ADMISSION_RATE = ENV["SIM_ADMISSION_RATE"]&.to_i
MODE        = ENV.fetch("SIM_MODE", "raids") # "raids" | "encounters"
ENCOUNTERS  = MODE == "encounters"
THROTTLE = ADMISSION_RATE ? Redis.new(url: ENV.fetch("SIM_REDIS_URL", "redis://localhost:6379/0")) : nil

BOSSES = %w[Mewtwo Rayquaza Kyogre Groudon Dialga Giratina Zacian Charizard Tyranitar Lugia].freeze

STATS = Hash.new(0)
LAT = []
RUN = { started: nil, reqs: 0, last_reqs: 0, targets: [], hot: [], peak: 0 }

def stat(key, delta = 1) = STATS[key] += delta

def pct(arr, p)
  return 0 if arr.empty?

  s = arr.sort
  s[[ (p * s.size).floor, s.size - 1 ].min]
end

def request(internet, sem, method, path, body = nil)
  sem.acquire do
    t0 = Async::Clock.now
    url = "#{BASE}#{path}"
    headers = body ? [ [ "content-type", "application/json" ] ] : []
    resp = method == :post ? internet.post(url, headers, body ? JSON.generate(body) : nil) : internet.get(url, headers)
    text = resp.read
    RUN[:reqs] += 1
    LAT << ((Async::Clock.now - t0) * 1000).round
    LAT.shift if LAT.size > 5000
    [ resp.status, text.to_s.empty? ? {} : JSON.parse(text) ]
  rescue StandardError => e
    stat(:errors)
    [ 0, { "error" => e.class.name } ]
  end
end

def pick_target
  pool = (!RUN[:hot].empty? && rand < HOT_BIAS) ? RUN[:hot] : RUN[:targets]
  pool.sample
end

# ---- Organizers: create + publish raids OR encounters ----
def seed_targets(internet, sem)
  TARGETS_N.times do |i|
    body, ok = seed_one(internet, sem, i)
    next unless ok

    id = body["id"]
    THROTTLE&.set(throttle_key(id), ADMISSION_RATE)
    RUN[:targets] << id
    stat(:targets_created)
  end
  RUN[:hot] = RUN[:targets].first([ RUN[:targets].size / 5, 1 ].max)
end

def seed_one(internet, sem, i)
  if ENCOUNTERS
    status, body = request(internet, sem, :post, "/encounters", {
      boss: BOSSES.sample, label: "Gym ##{i + 1}",
      starts_at: (Time.now + 3600).utc.iso8601, room_size: CAPACITY || 20
    })
    return [ {}, false ] unless status == 201

    request(internet, sem, :post, "/encounters/#{body['id']}/publish")
  else
    cap = CAPACITY || [ 5, 10, 15, 20, 40 ].sample
    status, body = request(internet, sem, :post, "/raids", {
      boss: BOSSES.sample, gym_name: "Gym ##{i + 1}",
      starts_at: (Time.now + 3600).utc.iso8601, capacity: cap
    })
    return [ {}, false ] unless status == 201

    request(internet, sem, :post, "/raids/#{body['id']}/publish")
  end
  [ body, true ]
end

def throttle_key(id) = ENCOUNTERS ? "admission:rate:enc:#{id}" : "admission:rate:#{id}"
def base_path(id)    = ENCOUNTERS ? "/encounters/#{id}" : "/raids/#{id}"

# ---- One virtual trainer's lifecycle ----
def run_trainer(internet, sem, idx, use_sse)
  handle = "sim_#{idx}"
  target = pick_target
  return unless target

  status, body = request(internet, sem, :post, "#{base_path(target)}/queue/join", { trainer_handle: handle })
  if status == 409
    stat(:full_on_join)
    return
  elsif status != 200
    return
  end

  token = body["token"]
  stat(:joined)
  stat(:in_queue)

  admitted, claim_secs, claim_target =
    use_sse ? wait_via_sse(internet, target, token) : wait_via_poll(internet, sem, handle, token, target)

  stat(:in_queue, -1)
  return unless admitted

  stat(:admitted)
  decide_claim(internet, sem, handle, claim_target, claim_secs)
end

def wait_via_poll(internet, sem, handle, token, target)
  abandon_at = (rand < 0.05) ? rand(2..6) : nil
  reconnect_at = (rand < 0.10) ? rand(2..5) : nil
  polls = 0

  loop do
    if reconnect_at && polls == reconnect_at
      sleep(rand(2.0..6.0))
      st, rb = request(internet, sem, :post, "#{base_path(target)}/queue/reconnect", { token: token })
      stat(:reconnects)
      if st == 200
        token = rb["token"] || token
        return [ true, rb["claim_seconds_remaining"], claim_target(rb, target) ] if rb["state"] == "admitted"
        return [ false, nil, nil ] if rb["state"] == "reserved"
      end
      reconnect_at = nil
    end

    if abandon_at && polls >= abandon_at
      stat(:abandoned_wait)
      return [ false, nil, nil ]
    end

    st, rb = request(internet, sem, :get, "#{base_path(target)}/queue/status?trainer_handle=#{handle}&token=#{token}")
    if st == 200 && rb["state"] == "admitted"
      return [ true, rb["claim_seconds_remaining"], claim_target(rb, target) ]
    elsif st == 404
      stat(ENCOUNTERS ? :abandoned_wait : :drained_waiting)
      return [ false, nil, nil ]
    end

    polls += 1
    return [ false, nil, nil ] if polls > 300

    sleep(rand(1.5..2.5))
  end
end

# In encounter mode the claim target is the assigned room id; in raid mode it's the raid itself.
def claim_target(status_body, target) = ENCOUNTERS ? status_body["room_id"] : target

def wait_via_sse(internet, target, token)
  resp = internet.get("#{BASE}#{base_path(target)}/queue/stream?token=#{token}")
  buffer = +""
  body = resp.body
  while (chunk = body.read)
    buffer << chunk
    while (i = buffer.index("\n\n"))
      block = buffer.slice!(0..i + 1)
      event = block[/event:\s*(\S+)/, 1]
      data = block[/data:\s*(.+)/, 1]
      next unless event

      stat(:sse_position) if event == "position"
      if event == "admitted"
        parsed = begin; data && JSON.parse(data); rescue StandardError; {}; end
        return [ true, parsed&.dig("claim_seconds_remaining"), ENCOUNTERS ? parsed&.dig("room_id") : target ]
      end
      if event == "raid_full"
        stat(:drained_waiting)
        return [ false, nil, nil ]
      end
    end
  end
  [ false, nil, nil ]
rescue StandardError
  [ false, nil, nil ]
ensure
  resp&.close
end

# Claim is the SAME endpoint in both modes: POST /raids/:room_or_raid_id/reservations.
def decide_claim(internet, sem, handle, claim_target, claim_secs)
  return stat(:errors) if claim_target.nil?

  window = (claim_secs && claim_secs > 0) ? claim_secs : 30
  roll = rand
  if roll < 0.70
    sleep(rand(0.2..2.0))
  elsif roll < 0.85
    sleep(rand(4.0..[ window - 3, 5 ].max))
  else
    sleep(window + rand(2.0..5.0))
    stat(:expired_afk)
    return
  end

  st, rb = request(internet, sem, :post, "/raids/#{claim_target}/reservations", { trainer_handle: handle })
  if [ 200, 201 ].include?(st)
    stat(:confirmed)
  elsif rb["error"] == "raid_full"
    stat(:lost_on_claim)
  elsif rb["error"] == "not_admitted"
    stat(:expired_afk)
  else
    stat(:errors)
  end
end

def full_count = STATS[:full_on_join] + STATS[:lost_on_claim] + STATS[:drained_waiting]

def report_line
  elapsed = (Async::Clock.now - RUN[:started]).round
  rps = RUN[:reqs] - RUN[:last_reqs]
  RUN[:last_reqs] = RUN[:reqs]
  RUN[:peak] = [ RUN[:peak], STATS[:in_queue] ].max
  format(
    "t=%3ds | queue=%-5d joined=%-5d admitted=%-5d confirmed=%-5d full=%-5d expired=%-4d aband=%-4d recon=%-4d err=%-3d | %4d req/s p50=%dms p95=%dms",
    elapsed, STATS[:in_queue], STATS[:joined], STATS[:admitted], STATS[:confirmed],
    full_count, STATS[:expired_afk], STATS[:abandoned_wait], STATS[:reconnects], STATS[:errors],
    rps, pct(LAT, 0.5), pct(LAT, 0.95)
  )
end

# ---- Orchestration ----
Async do |task|
  internet = Async::HTTP::Internet.new
  sem = Async::Semaphore.new(CONCURRENCY)
  RUN[:started] = Async::Clock.now

  puts "Simulating #{TRAINERS} trainers over #{TARGETS_N} #{ENCOUNTERS ? 'encounters' : 'raids'} → #{BASE} " \
       "(arrival #{DURATION}s, #{SSE_USERS} SSE, concurrency #{CONCURRENCY})"
  seed_targets(internet, sem)
  puts "Seeded #{RUN[:targets].size} #{ENCOUNTERS ? 'encounters' : 'raids'} (#{RUN[:hot].size} hot). Releasing trainers…"

  reporter = task.async do
    loop do
      sleep 1
      puts report_line
    end
  end

  sessions = []
  TRAINERS.times do |i|
    sessions << task.async { run_trainer(internet, sem, i, i < SSE_USERS) }
    sleep(rand * (DURATION / TRAINERS) * 2)
  end
  sessions.each(&:wait)

  # Integrity: per target, confirmed reservations must never exceed capacity (no oversell).
  claimed_total = 0
  oversold = []
  RUN[:targets].each do |id|
    if ENCOUNTERS
      _st, m = request(internet, sem, :get, "/encounters/#{id}/metrics")
      next unless m["room_breakdown"]

      claimed_total += m["confirmed"].to_i
      oversold << id if m["room_breakdown"].any? { |r| r["confirmed"] > r["room_size"] }
    else
      _st, m = request(internet, sem, :get, "/raids/#{id}/metrics")
      next unless m["capacity"]

      claimed_total += (m["capacity"] - m["slots_remaining"])
      oversold << id if m["slots_remaining"].negative?
    end
  end

  reporter.stop
  internet.close

  puts "\n===== SUMMARY (#{MODE}) ====="
  %i[targets_created joined full_on_join drained_waiting admitted confirmed lost_on_claim
     expired_afk abandoned_wait reconnects sse_position errors].each { |k| puts format("  %-18s %d", k, STATS[k]) }
  accounted = STATS[:confirmed] + full_count + STATS[:expired_afk] + STATS[:abandoned_wait]
  puts format("  %-18s %d / %d trainers", "accounted", accounted, TRAINERS)
  puts format("  %-18s %d", "peak queue depth", RUN[:peak])
  puts format("  latency            p50=%dms p95=%dms p99=%dms", pct(LAT, 0.5), pct(LAT, 0.95), pct(LAT, 0.99))

  puts "\n===== INTEGRITY ====="
  ok = oversold.empty? && claimed_total == STATS[:confirmed]
  puts format("  slots consumed: %d   confirmed claims: %d", claimed_total, STATS[:confirmed])
  puts format("  oversold %s: %s", ENCOUNTERS ? "rooms" : "raids", oversold.empty? ? "NONE ✓" : oversold.inspect)
  puts ok ? "  ✅ NO OVERSELL" : "  ❌ MISMATCH — investigate!"
end
