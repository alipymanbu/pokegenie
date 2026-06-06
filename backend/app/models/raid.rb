class Raid < ApplicationRecord
  STATUSES = %w[draft published closed].freeze

  has_many :reservations, dependent: :restrict_with_exception

  validates :boss, :gym_name, presence: true
  validates :starts_at, presence: true
  validates :capacity, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }
  # slots_remaining bounds are enforced by DB CHECK constraints (the real guarantee);
  # this is a friendly mirror for in-app validation paths.
  validates :slots_remaining,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true

  before_validation :default_slots_remaining, on: :create

  def published? = status == "published"
  def full?      = slots_remaining.to_i <= 0
  def joinable?  = published? && !full?

  private

  def default_slots_remaining
    self.slots_remaining ||= capacity
  end
end
