class RaidsController < ApplicationController
  before_action :find_raid, only: %i[show metrics publish]

  # GET /raids — published raids trainers can queue for
  def index
    raids = Raid.where(status: "published").order(starts_at: :asc)
    render json: { raids: raids.map { |r| raid_json(r) } }
  end

  # GET /raids/:id
  def show
    render json: raid_json(@raid)
  end

  # POST /raids — organizer creates a raid (FR-012). Starts as draft.
  def create
    raid = Raid.create!(raid_params.merge(status: "draft"))
    render json: raid_json(raid), status: :created
  end

  # POST /raids/:id/publish — open the raid for queuing (FR-012)
  def publish
    @raid.update!(status: "published") unless @raid.status == "closed"
    render json: raid_json(@raid)
  end

  # GET /raids/:id/metrics — operational view (FR-016, SC-007, Principle VII)
  def metrics
    counters = QueueRedis.with do |r|
      {
        queue_depth: r.zcard(QueueConfig.queue_key(@raid.id)),
        claims_total: r.get(QueueConfig.metric_claims_key(@raid.id)).to_i,
        conflicts_total: r.get(QueueConfig.metric_conflicts_key(@raid.id)).to_i,
        admitted_total: r.get(QueueConfig.metric_admitted_key(@raid.id)).to_i
      }
    end
    claims = counters[:claims_total]
    render json: {
      raid_id: @raid.id,
      queue_depth: counters[:queue_depth],
      slots_remaining: @raid.slots_remaining,
      capacity: @raid.capacity,
      claims_total: claims,
      conflicts_total: counters[:conflicts_total],
      admitted_total: counters[:admitted_total],
      conflict_rate: claims.positive? ? (counters[:conflicts_total].to_f / claims).round(4) : 0.0
    }
  end

  private

  def raid_params
    params.permit(:boss, :gym_name, :starts_at, :capacity, :latitude, :longitude)
  end

  def raid_json(raid)
    {
      id: raid.id,
      boss: raid.boss,
      gym_name: raid.gym_name,
      starts_at: raid.starts_at&.iso8601,
      capacity: raid.capacity,
      slots_remaining: raid.slots_remaining,
      status: raid.status
    }
  end
end
