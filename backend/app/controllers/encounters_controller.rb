class EncountersController < ApplicationController
  before_action :find_encounter, only: %i[show publish metrics]

  # GET /encounters
  def index
    encounters = Encounter.where(status: "published").order(starts_at: :asc)
    render json: { encounters: encounters.map { |e| encounter_json(e) } }
  end

  # GET /encounters/:id
  def show
    render json: encounter_json(@encounter)
  end

  # POST /encounters — organizer creates (draft). Rooms are system-spawned, not created here.
  def create
    enc = Encounter.create!(encounter_params.merge(status: "draft"))
    render json: encounter_json(enc), status: :created
  end

  # POST /encounters/:id/publish
  def publish
    @encounter.update!(status: "published") unless @encounter.status == "closed"
    render json: encounter_json(@encounter)
  end

  # GET /encounters/:id/metrics — aggregate across the encounter's rooms + live queue depth
  def metrics
    rooms = @encounter.rooms
    confirmed = Reservation.where(raid_id: rooms.select(:id), status: "confirmed").count
    depth = QueueRedis.with { |r| r.zcard(QueueConfig.enc_queue_key(@encounter.id)) }
    render json: {
      encounter_id: @encounter.id,
      queue_depth: depth,
      rooms: rooms.count,
      room_size: @encounter.room_size,
      confirmed: confirmed,
      capacity_so_far: rooms.count * @encounter.room_size
    }
  end

  private

  def find_encounter
    @encounter = Encounter.find(params[:id] || params[:encounter_id])
  end

  def encounter_params
    params.permit(:boss, :label, :starts_at, :room_size)
  end

  def encounter_json(enc)
    {
      id: enc.id, boss: enc.boss, label: enc.label,
      starts_at: enc.starts_at&.iso8601, room_size: enc.room_size,
      status: enc.status, rooms: enc.rooms.count
    }
  end
end
