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
  # One encounter per boss: if this Pokémon already has a live encounter, funnel into it
  # instead of spawning a parallel one. The DB unique index is the real guard; the rescue
  # makes a lost create race resolve to the winner rather than 500.
  def create
    if (existing = Encounter.active_for_boss(encounter_params[:boss]))
      return render json: encounter_json(existing), status: :ok
    end
    enc = Encounter.create!(encounter_params.merge(status: "draft"))
    render json: encounter_json(enc), status: :created
  rescue ActiveRecord::RecordNotUnique
    render json: encounter_json(Encounter.active_for_boss(encounter_params[:boss])), status: :ok
  end

  # POST /encounters/:id/publish
  def publish
    @encounter.update!(status: "published") unless @encounter.status == "closed"
    render json: encounter_json(@encounter)
  end

  # GET /encounters/:id/metrics — live queue depth + per-room fill (for the operator view)
  def metrics
    rooms = @encounter.rooms.order(:room_number)
    now = Time.now.to_i
    size = @encounter.room_size
    room_rows = rooms.map do |room|
      confirmed = size - room.slots_remaining
      holding = QueueRedis.with { |r| r.zcount(QueueConfig.room_holds_key(room.id), "(#{now}", "+inf") }
      { room_number: room.room_number, room_size: size, confirmed: confirmed,
        holding: holding, free: [ size - confirmed - holding, 0 ].max }
    end
    depth = QueueRedis.with { |r| r.zcard(QueueConfig.enc_queue_key(@encounter.id)) }
    admitted = QueueRedis.with { |r| r.get(QueueConfig.enc_metric_admitted_key(@encounter.id)).to_i }
    render json: {
      encounter_id: @encounter.id,
      queue_depth: depth,
      rooms: rooms.count,
      room_size: size,
      admitted_total: admitted,
      confirmed: room_rows.sum { |r| r[:confirmed] },
      capacity_so_far: rooms.count * size,
      room_breakdown: room_rows
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
