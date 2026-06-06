class Trainer < ApplicationRecord
  has_many :reservations, dependent: :restrict_with_exception

  validates :handle, presence: true, uniqueness: { case_sensitive: false }

  # Stable identity used to preserve a trainer's place across reconnects.
  def self.find_or_create_by_handle!(handle)
    find_or_create_by!(handle: handle.to_s.strip)
  end
end
