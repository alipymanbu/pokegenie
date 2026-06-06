class QueueStreamsController < ApplicationController
  include ActionController::Live

  # GET /raids/:raid_id/queue/stream?token=... (FR-004, Principle V)
  # Server→client SSE: instant admitted/raid_full via Redis Pub/Sub, plus a periodic position
  # tick (POSITION_PUSH_MS) that doubles as a keepalive AND a fallback if a pub/sub message is
  # missed. See contracts/sse-events.md.
  def show
    raid = Raid.find(params[:raid_id])
    trainer = resolve_trainer
    return render_error(:not_found, "gone", "Not in line; token expired or never joined") unless trainer

    setup_sse_headers
    sse = ActionController::Live::SSE.new(response.stream)
    inbox = Thread::Queue.new
    subscriber = start_subscriber(raid.id, trainer.id, inbox)
    interval = QueueConfig::POSITION_PUSH_MS / 1000.0

    # Send current state immediately; bail if already terminal (admitted / gone).
    return if push_state(sse, raid.id, trainer.id) == :stop

    loop do
      event = inbox.pop(timeout: interval) # nil on timeout → periodic tick
      if event
        sse.write(event[:data], event: event[:name])
        break if terminal?(event[:name])
      else
        break if push_state(sse, raid.id, trainer.id) == :stop
      end
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # Client closed the tab / network dropped — normal end of stream.
  ensure
    subscriber&.kill
    sse&.close
  end

  private

  def setup_sse_headers
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no" # don't let proxies buffer the stream
    # EventSource can't send custom headers, but it does send Origin; echo it so the browser
    # accepts the stream (rack-cors covers non-streaming responses).
    origin = request.headers["Origin"]
    response.headers["Access-Control-Allow-Origin"] = origin if origin.present?
  end

  # Background thread: forwards only THIS trainer's events from the raid channel into `inbox`.
  def start_subscriber(raid_id, trainer_id, inbox)
    Thread.new do
      redis = QueueRedis.dedicated
      redis.subscribe(QueueConfig.events_channel(raid_id)) do |on|
        on.message do |_channel, payload|
          msg = JSON.parse(payload)
          next unless msg["trainer_id"].to_s == trainer_id.to_s

          inbox << { name: msg["event"], data: msg["data"] }
        end
      end
    rescue => e
      Rails.logger.warn("[sse] subscriber ended for raid=#{raid_id} trainer=#{trainer_id}: #{e.class}: #{e.message}")
    ensure
      redis&.close
    end
  end

  # Writes the current queue state. Returns :continue (still waiting) or :stop (terminal).
  def push_state(sse, raid_id, trainer_id)
    result = RaidQueue::Position.call(raid_id: raid_id, trainer_id: trainer_id)
    if result.ok? && result.data[:state] == "waiting"
      # The live connection IS the presence heartbeat (FR-010): refresh the grace TTL each tick.
      QueueRedis.with { |r| r.set(QueueConfig.presence_key(raid_id, trainer_id), "1", ex: QueueConfig::RECONNECT_GRACE_SECONDS) }
      sse.write({ position: result.data[:position], depth: result.data[:depth] }, event: "position")
      :continue
    elsif result.ok? && result.data[:state] == "admitted"
      sse.write({ raid_id: raid_id, claim_seconds_remaining: result.data[:claim_seconds_remaining] }, event: "admitted")
      :stop
    else
      sse.write({ error: "gone" }, event: "raid_full")
      :stop
    end
  end

  def terminal?(event_name)
    %w[admitted raid_full].include?(event_name)
  end

  def resolve_trainer
    if params[:trainer_handle].present?
      Trainer.find_by(handle: params[:trainer_handle])
    elsif params[:token].present?
      payload = QueueRedis.with { |r| r.get(QueueConfig.token_key(params[:token])) }
      payload && Trainer.find_by(id: JSON.parse(payload)["trainer_id"])
    end
  end
end
