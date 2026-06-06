class Reservation < ApplicationRecord
  belongs_to :raid
  belongs_to :trainer

  validates :status, presence: true
  # Uniqueness (raid_id, trainer_id) is enforced by a DB unique index — the authoritative
  # idempotency guarantee (INV-2). This validation is a friendly pre-check only.
  validates :trainer_id, uniqueness: { scope: :raid_id }
end
