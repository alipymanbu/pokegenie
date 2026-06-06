class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound do |e|
    render_error(:not_found, "not_found", e.message)
  end
  rescue_from ActiveRecord::RecordInvalid do |e|
    render_error(:unprocessable_entity, "validation_failed", e.message)
  end
  rescue_from ActionController::ParameterMissing do |e|
    render_error(:unprocessable_entity, "validation_failed", e.message)
  end

  private

  def render_error(status, code, message = nil)
    render json: { error: code, message: message || code.to_s.humanize }, status: status
  end

  def find_raid
    @raid = Raid.find(params[:id] || params[:raid_id])
  end

  def trainer_from_params
    handle = params.require(:trainer_handle)
    Trainer.find_or_create_by_handle!(handle)
  end
end
