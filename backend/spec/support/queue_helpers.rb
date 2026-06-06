module QueueHelpers
  def create_raid(capacity:, status: "published", **attrs)
    Raid.create!(
      boss: attrs[:boss] || "Mewtwo",
      gym_name: attrs[:gym_name] || "Test Gym",
      starts_at: attrs[:starts_at] || 1.hour.from_now,
      capacity: capacity,
      slots_remaining: attrs.fetch(:slots_remaining, capacity),
      status: status
    )
  end

  def create_trainers(n)
    Array.new(n) { |i| Trainer.create!(handle: "trainer_#{i}_#{SecureRandom.hex(3)}") }
  end

  # Mark a trainer as admitted (bypasses the worker; the claim flow gate checks this set).
  def admit!(raid, trainer)
    QueueRedis.with { |r| r.sadd(QueueConfig.admitted_key(raid.id), trainer.id.to_s) }
  end

  def confirmed_count(raid)
    Reservation.where(raid_id: raid.id, status: "confirmed").count
  end

  # Run `block` across `count` threads released as simultaneously as possible to maximize
  # contention. Returns the array of per-thread return values.
  def run_concurrently(count)
    ready = Queue.new
    results = Array.new(count)
    start = false
    mutex = Mutex.new
    cond = ConditionVariable.new

    threads = (0...count).map do |i|
      Thread.new do
        ready << true
        mutex.synchronize { cond.wait(mutex) until start }
        begin
          results[i] = yield(i)
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
    end

    count.times { ready.pop } # wait until every thread is parked at the gate
    mutex.synchronize { start = true; cond.broadcast }
    threads.each(&:join)
    results
  end
end

RSpec.configure do |config|
  config.include QueueHelpers
end
