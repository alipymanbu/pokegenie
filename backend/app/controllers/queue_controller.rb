class QueueController < ApplicationController
  before_action :find_raid

  # POST /raids/:raid_id/queue/join (FR-001/002/013)
  def join
    trainer = trainer_from_params
    result = RaidQueue::Join.call(raid: @raid, trainer: trainer)

    if result.ok?
      render json: queue_status_json(result), status: :ok
    else
      render_error(:conflict, result.code.to_s, join_error_message(result.code))
    end
  end

  # GET /raids/:raid_id/queue/status?token=... (FR-003)
  # Token is accepted for reconnect semantics; in this MVP the trainer handle resolves the
  # position. Reconnect (US3) will use the token to restore an expired place.
  def status
    trainer = Trainer.find_by(handle: params[:trainer_handle]) if params[:trainer_handle]
    trainer ||= trainer_from_token
    return render_error(:not_found, "gone", "Not in line; token expired or never joined") unless trainer

    result = RaidQueue::Position.call(raid_id: @raid.id, trainer_id: trainer.id)
    if result.ok?
      render json: result.data.merge(raid_id: @raid.id)
    else
      render_error(:not_found, "gone", "Not in line; token expired or already admitted/claimed")
    end
  end

  private

  def trainer_from_token
    token = params[:token]
    return nil if token.blank?

    payload = QueueRedis.with { |r| r.get(QueueConfig.token_key(token)) }
    return nil if payload.blank?

    Trainer.find_by(id: JSON.parse(payload)["trainer_id"])
  end

  def queue_status_json(result)
    {
      token: result.data[:token],
      state: result.data[:state],
      position: result.data[:position],
      depth: result.data[:depth],
      raid_id: @raid.id
    }
  end

  def join_error_message(code)
    case code
    when :raid_full then "This raid is full."
    when :not_published then "This raid is not open for queuing yet."
    else code.to_s
    end
  end
end
