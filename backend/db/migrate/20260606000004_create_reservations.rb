class CreateReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :reservations do |t|
      t.references :raid, null: false, foreign_key: { on_delete: :restrict }
      t.references :trainer, null: false, foreign_key: { on_delete: :restrict }
      t.string :status, null: false, default: "confirmed"
      t.timestamps
    end

    # Idempotency / INV-2: at most one reservation per trainer per raid.
    add_index :reservations, [ :raid_id, :trainer_id ], unique: true, name: "index_reservations_unique_trainer_per_raid"
  end
end
