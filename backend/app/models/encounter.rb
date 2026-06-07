class Encounter < ApplicationRecord
  STATUSES = %w[draft published closed].freeze

  has_many :rooms, class_name: "Raid", dependent: :restrict_with_exception

  validates :boss, :label, presence: true
  validates :starts_at, presence: true
  validates :room_size, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  # Not yet closed — the states in which a boss already has a live encounter to queue into.
  scope :active, -> { where.not(status: "closed") }

  # The single active encounter for a boss, if one exists (case-insensitive).
  # Backed by index_encounters_unique_active_boss, so there is at most one.
  def self.active_for_boss(boss)
    active.where("lower(boss) = lower(?)", boss.to_s.strip).order(:id).first
  end

  def published? = status == "published"
end
