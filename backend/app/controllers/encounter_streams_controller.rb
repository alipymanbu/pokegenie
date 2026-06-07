class EncounterStreamsController < ApplicationController
  include ActionController::Live

  # GET /encounters/:encounter_id/queue/stream?token=... (SSE; FE-005)
  # Pushes 'position' on a tick and 'admitted' (with the assigned room) instantly via pub/sub,
  # with the periodic tick as a fallback. Mirrors QueueStreamsController.
  def show
    @encounter = Encounter.find(params[:encounter_id])
    trainer = resolve_trainer
    return render_error(:not_found, "gone", "Not in line") unless trainer

    setup_sse_headers
    sse = ActionController::Live::SSE.new(response.stream)
    inbox = Thread::Queue.new
    subscriber = start_subscriber(@encounter.id, trainer.id, inbox)
    interval = QueueConfig::POSITION_PUSH_MS / 1000.0

    return if push_state(sse, trainer.id) == :stop

    loop do
      event = inbox.pop(timeout: interval)
      if event
        sse.write(event[:data], event: event[:name])
        break if event[:name] == "admitted"
      elsif push_state(sse, trainer.id) == :stop
        break
      end
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # normal end of stream
  ensure
    subscriber&.kill
    sse&.close
  end

  private

  def setup_sse_headers
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    origin = request.headers["Origin"]
    response.headers["Access-Control-Allow-Origin"] = origin if origin.present?
  end

  def start_subscriber(enc_id, trainer_id, inbox)
    Thread.new do
      redis = QueueRedis.dedicated
      redis.subscribe(QueueConfig.enc_events_channel(enc_id)) do |on|
        on.message do |_channel, payload|
          msg = JSON.parse(payload)
          next unless msg["trainer_id"].to_s == trainer_id.to_s

          inbox << { name: msg["event"], data: msg["data"] }
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[sse:enc] subscriber ended: #{e.class}: #{e.message}")
    ensure
      redis&.close
    end
  end

  def push_state(sse, trainer_id)
    result = Encounters::Position.call(encounter: @encounter, trainer_id: trainer_id)
    return :stop unless result.ok?

    case result.data[:state]
    when "waiting"
      QueueRedis.with { |r| r.set(QueueConfig.enc_presence_key(@encounter.id, trainer_id), "1", ex: QueueConfig::RECONNECT_GRACE_SECONDS) }
      sse.write({ position: result.data[:position], depth: result.data[:depth] }, event: "position")
      :continue
    when "admitted"
      sse.write({ encounter_id: @encounter.id, room_id: result.data[:room_id],
                  room_number: result.data[:room_number],
                  claim_seconds_remaining: result.data[:claim_seconds_remaining] }, event: "admitted")
      :stop
    else # reserved / gone
      sse.write({ room_id: result.data[:room_id], room_number: result.data[:room_number] }, event: "admitted")
      :stop
    end
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
