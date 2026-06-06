class ReservationsController < ApplicationController
  before_action :find_raid

  # POST /raids/:raid_id/reservations (FR-006/007/008/009)
  def create
    trainer = trainer_from_params
    result = Reservations::Claim.call(raid: @raid, trainer: trainer)

    if result.ok?
      status = result.data[:idempotent] ? :ok : :created
      render json: reservation_json(result.data[:reservation], trainer), status: status
    else
      render_error(:conflict, result.code.to_s, claim_error_message(result.code))
    end
  end

  private

  def reservation_json(reservation, trainer)
    {
      id: reservation.id,
      raid_id: reservation.raid_id,
      trainer_handle: trainer.handle,
      status: reservation.status,
      created_at: reservation.created_at.iso8601
    }
  end

  def claim_error_message(code)
    case code
    when :raid_full then "This raid is full — no slots remain."
    when :not_admitted then "You have not been admitted from the queue yet."
    else code.to_s
    end
  end
end
