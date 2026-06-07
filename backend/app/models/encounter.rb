class Encounter < ApplicationRecord
  STATUSES = %w[draft published closed].freeze

  has_many :rooms, class_name: "Raid", dependent: :restrict_with_exception

  validates :boss, :label, presence: true
  validates :starts_at, presence: true
  validates :room_size, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  def published? = status == "published"
end
