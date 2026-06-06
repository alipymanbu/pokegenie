# frozen_string_literal: true

# Real-world load/behavior simulator for the PokeGenie Raid Queue.
#
# Spawns thousands of fiber-based "virtual trainers" (via the `async` gem) that drive the REAL
# HTTP API — organizers create/publish raids, trainers arrive over time, queue, get admitted or
# rejected, and either claim promptly, claim late, or go AFK until their hold expires. A handful
# hold real SSE connections; some drop and reconnect mid-wait.
#
# Run (from backend/):
#   bundle exec ruby sim/simulate.rb
#
# Tunables (ENV):
#   SIM_BASE=http://localhost:3002   SIM_TRAINERS=2000   SIM_RAIDS=25
#   SIM_DURATION=120 (arrival window, s)   SIM_SSE=20   SIM_CONCURRENCY=200
#
# NOTE: point this at a backend tuned for the load, e.g.
#   RAILS_MAX_THREADS=64 REDIS_POOL_SIZE=80 CLAIM_WINDOW_SECONDS=30 bin/rails server -p 3002
# and have the admission worker running:  CLAIM_WINDOW_SECONDS=30 bin/rails admission:run

# Quiet the benign experimental/io-event warnings and async-http's shutdown-race log noise.
ENV["CONSOLE_LEVEL"] ||= "error"
Warning[:experimental] = false
$stdout.sync = true # flush per-second lines immediately (so background runs are tail-able)

require "async"
require "async/http/internet"
require "async/semaphore"
require "redis"
require "json"

BASE        = ENV.fetch("SIM_BASE", "http://localhost:3002")
TRAINERS    = ENV.fetch("SIM_TRAINERS", "2000").to_i
RAIDS       = ENV.fetch("SIM_RAIDS", "25").to_i
DURATION    = ENV.fetch("SIM_DURATION", "120").to_f   # arrival window
SSE_USERS   = ENV.fetch("SIM_SSE", "20").to_i
CONCURRENCY = ENV.fetch("SIM_CONCURRENCY", "200").to_i
HOT_BIAS    = ENV.fetch("SIM_HOT_BIAS", "0.6").to_f   # P(a trainer herds into a hot raid)
CAPACITY    = ENV["SIM_CAPACITY"]&.to_i              # fixed capacity override (else randomized)
# Throttle admission via the control-plane key (deep queues). nil = server default batch.
ADMISSION_RATE = ENV["SIM_ADMISSION_RATE"]&.to_i
THROTTLE = ADMISSION_RATE ? Redis.new(url: ENV.fetch("SIM_REDIS_URL", "redis://localhost:6379/0")) : nil

BOSSES = %w[Mewtwo Rayquaza Kyogre Groudon Dialga Giratina Zacian Charizard Tyranitar Lugia].freeze

# Single-reactor fibers are cooperative → plain integer counters are race-free (no mutex needed).
STATS = Hash.new(0)
LAT = [] # request latencies (ms), recent sample
RUN = { started: nil, reqs: 0, last_reqs: 0, raids: [], hot: [] }

def stat(key, delta = 1) = STATS[key] += delta

def pct(arr, p)
  return 0 if arr.empty?

  sorted = arr.sort
  sorted[[ (p * sorted.size).floor, sorted.size - 1 ].min]
end

# ---- HTTP helper (short requests pass through the concurrency semaphore) ----
def request(internet, sem, method, path, body = nil)
  sem.acquire do
    t0 = Async::Clock.now
    url = "#{BASE}#{path}"
    headers = body ? [ [ "content-type", "application/json" ] ] : []
    resp =
      if method == :post
        internet.post(url, headers, body ? JSON.generate(body) : nil)
      else
        internet.get(url, headers)
      end
    text = resp.read
    RUN[:reqs] += 1
    LAT << ((Async::Clock.now - t0) * 1000).round
    LAT.shift if LAT.size > 5000
    [ resp.status, text.to_s.empty? ? {} : JSON.parse(text) ]
  rescue => e
    stat(:errors)
    [ 0, { "error" => e.class.name } ]
  end
end

def pick_raid
  # Herd into a "hot" raid with probability HOT_BIAS; else uniform.
  pool = (!RUN[:hot].empty? && rand < HOT_BIAS) ? RUN[:hot] : RUN[:raids]
  pool.sample
end

# ---- Organizers: create + publish raids, mark a few "hot" ----
def seed_raids(internet, sem)
  RAIDS.times do |i|
    cap = CAPACITY || [ 5, 10, 15, 20, 40 ].sample
    status, body = request(internet, sem, :post, "/raids", {
      boss: BOSSES.sample, gym_name: "Gym ##{i + 1}",
      starts_at: (Time.now + 3600).utc.iso8601, capacity: cap
    })
    next unless status == 201

    request(internet, sem, :post, "/raids/#{body['id']}/publish")
    # Throttle this raid's admission via the control-plane key → deep, persistent lines.
    THROTTLE&.set("admission:rate:#{body['id']}", ADMISSION_RATE)
    RUN[:raids] << body["id"]
    stat(:raids_created)
  end
  RUN[:hot] = RUN[:raids].first([ RUN[:raids].size / 5, 1 ].max) # ~20% are hot
end

# ---- One virtual trainer's lifecycle ----
def run_trainer(internet, sem, idx, use_sse)
  handle = "sim_#{idx}"
  raid_id = pick_raid
  return unless raid_id

  status, body = request(internet, sem, :post, "/raids/#{raid_id}/queue/join", { trainer_handle: handle })
  if status == 409
    stat(:full_on_join)
    return
  elsif status != 200
    return
  end

  token = body["token"]
  stat(:joined)
  stat(:in_queue)

  admitted, claim_secs =
    if use_sse
      wait_via_sse(internet, raid_id, token)
    else
      wait_via_poll(internet, sem, handle, token, raid_id)
    end

  stat(:in_queue, -1)
  return unless admitted

  stat(:admitted)
  decide_claim(internet, sem, handle, raid_id, claim_secs)
end

# Poll status until admitted; models abandon-while-waiting and a mid-wait reconnect.
def wait_via_poll(internet, sem, handle, token, raid_id)
  abandon_at = (rand < 0.05) ? rand(2..6) : nil
  reconnect_at = (rand < 0.10) ? rand(2..5) : nil
  polls = 0

  loop do
    if reconnect_at && polls == reconnect_at
      sleep(rand(2.0..6.0)) # simulate a dropped connection
      st, rb = request(internet, sem, :post, "/raids/#{raid_id}/queue/reconnect", { token: token })
      stat(:reconnects)
      if st == 200
        token = rb["token"] || token
        return [ true, rb["claim_seconds_remaining"] ] if rb["state"] == "admitted"
        return [ false, nil ] if rb["state"] == "reserved"
      end
      reconnect_at = nil
    end

    if abandon_at && polls >= abandon_at
      stat(:abandoned_wait)
      return [ false, nil ] # disconnect forever
    end

    st, rb = request(internet, sem, :get, "/raids/#{raid_id}/queue/status?trainer_handle=#{handle}&token=#{token}")
    if st == 200
      return [ true, rb["claim_seconds_remaining"] ] if rb["state"] == "admitted"
    elsif st == 404
      stat(:drained_waiting) # raid filled and we were drained from the line
      return [ false, nil ]
    end

    polls += 1
    return [ false, nil ] if polls > 300 # safety valve

    sleep(rand(1.5..2.5))
  end
end

# Hold a real SSE connection and react to pushed events.
def wait_via_sse(internet, raid_id, token)
  resp = internet.get("#{BASE}/raids/#{raid_id}/queue/stream?token=#{token}")
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
        secs = begin; data && JSON.parse(data)["claim_seconds_remaining"]; rescue StandardError; nil; end
        return [ true, secs ]
      end
      if event == "raid_full"
        stat(:drained_waiting)
        return [ false, nil ]
      end
    end
  end
  [ false, nil ]
rescue StandardError
  [ false, nil ]
ensure
  resp&.close
end

# On admission: claim promptly (70%), claim late (15%), or go AFK past the window (15%).
def decide_claim(internet, sem, handle, raid_id, claim_secs)
  window = (claim_secs && claim_secs > 0) ? claim_secs : 30
  roll = rand

  if roll < 0.70
    sleep(rand(0.2..2.0))
  elsif roll < 0.85
    sleep(rand(4.0..[ window - 3, 5 ].max))
  else
    sleep(window + rand(2.0..5.0)) # AFK until the hold lapses
    stat(:expired_afk)
    return
  end

  st, rb = request(internet, sem, :post, "/raids/#{raid_id}/reservations", { trainer_handle: handle })
  if [ 200, 201 ].include?(st)
    stat(:confirmed)
  elsif rb["error"] == "raid_full"
    stat(:lost_on_claim)
  elsif rb["error"] == "not_admitted"
    stat(:expired_afk) # window lapsed just before claiming
  else
    stat(:errors)
  end
end

def full_count = STATS[:full_on_join] + STATS[:lost_on_claim] + STATS[:drained_waiting]

def report_line
  elapsed = (Async::Clock.now - RUN[:started]).round
  rps = RUN[:reqs] - RUN[:last_reqs]
  RUN[:last_reqs] = RUN[:reqs]
  RUN[:peak] = [ RUN[:peak].to_i, STATS[:in_queue] ].max
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

  puts "Simulating #{TRAINERS} trainers over #{RAIDS} raids → #{BASE} " \
       "(arrival #{DURATION}s, #{SSE_USERS} SSE, concurrency #{CONCURRENCY})"
  seed_raids(internet, sem)
  puts "Seeded #{RUN[:raids].size} raids (#{RUN[:hot].size} hot). Releasing trainers…"

  reporter = task.async do
    loop do
      sleep 1
      puts report_line
    end
  end

  # Spawn trainers with staggered (jittered) arrivals across the arrival window.
  sessions = []
  TRAINERS.times do |i|
    sessions << task.async { run_trainer(internet, sem, i, i < SSE_USERS) }
    sleep(rand * (DURATION / TRAINERS) * 2)
  end
  sessions.each(&:wait) # wait for every session to reach a terminal state (incl. AFK timeouts)

  # Integrity check (the headline guarantee): per raid, confirmed reservations must equal
  # capacity - slots_remaining and never exceed capacity. Done before closing the client.
  claimed_total = 0
  oversold = []
  RUN[:raids].each do |rid|
    _st, m = request(internet, sem, :get, "/raids/#{rid}/metrics")
    next unless m["capacity"]

    claimed_total += (m["capacity"] - m["slots_remaining"])
    oversold << rid if m["slots_remaining"].negative? || m["slots_remaining"] > m["capacity"]
  end

  reporter.stop
  internet.close

  puts "\n===== SUMMARY ====="
  %i[raids_created joined full_on_join drained_waiting admitted confirmed lost_on_claim
     expired_afk abandoned_wait reconnects sse_position errors].each do |k|
    puts format("  %-18s %d", k, STATS[k])
  end
  accounted = STATS[:confirmed] + full_count + STATS[:expired_afk] + STATS[:abandoned_wait]
  puts format("  %-18s %d / %d trainers", "accounted", accounted, TRAINERS)
  puts format("  %-18s %d", "peak queue depth", RUN[:peak].to_i)
  puts format("  latency            p50=%dms p95=%dms p99=%dms", pct(LAT, 0.5), pct(LAT, 0.95), pct(LAT, 0.99))

  puts "\n===== INTEGRITY ====="
  ok = oversold.empty? && claimed_total == STATS[:confirmed]
  puts format("  slots consumed across raids: %d   confirmed claims: %d", claimed_total, STATS[:confirmed])
  puts format("  oversold raids: %s", oversold.empty? ? "NONE ✓" : oversold.inspect)
  puts ok ? "  ✅ NO OVERSELL — every confirmed claim maps to exactly one slot." \
          : "  ❌ MISMATCH — investigate!"
end
