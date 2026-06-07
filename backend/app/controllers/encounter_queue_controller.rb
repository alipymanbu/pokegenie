class EncounterQueueController < ApplicationController
  before_action :find_encounter

  # POST /encounters/:encounter_id/queue/join
  def join
    trainer = trainer_from_params
    result = Encounters::Join.call(encounter: @encounter, trainer: trainer)
    if result.ok?
      render json: result.data.merge(encounter_id: @encounter.id)
    else
      render_error(:conflict, result.code.to_s, "This encounter is not open for queuing yet.")
    end
  end

  # GET /encounters/:encounter_id/queue/status?token=...&trainer_handle=...
  def status
    trainer = resolve_trainer
    return render_error(:not_found, "gone", "Not in line; token expired or never joined") unless trainer

    result = Encounters::Position.call(encounter: @encounter, trainer_id: trainer.id)
    if result.ok?
      heartbeat(trainer.id) if result.data[:state] == "waiting"
      render json: result.data.merge(encounter_id: @encounter.id)
    else
      render_error(:not_found, "gone", "Not in line")
    end
  end

  # POST /encounters/:encounter_id/queue/reconnect
  def reconnect
    result = Encounters::Reconnect.call(encounter: @encounter, token: params[:token].to_s)
    if result.ok?
      render json: result.data.merge(encounter_id: @encounter.id, reservation_id: nil)
    else
      render_error(:not_found, "expired", "Your place could not be restored; please rejoin.")
    end
  end

  private

  def find_encounter
    @encounter = Encounter.find(params[:encounter_id])
  end

  def resolve_trainer
    if params[:trainer_handle].present?
      Trainer.find_by(handle: params[:trainer_handle])
    elsif params[:token].present?
      payload = QueueRedis.with { |r| r.get(QueueConfig.token_key(params[:token])) }
      payload && Trainer.find_by(id: JSON.parse(payload)["trainer_id"])
    end
  end

  def heartbeat(trainer_id)
    QueueRedis.with do |r|
      r.set(QueueConfig.enc_presence_key(@encounter.id, trainer_id), "1", ex: QueueConfig::RECONNECT_GRACE_SECONDS)
    end
  end
end
