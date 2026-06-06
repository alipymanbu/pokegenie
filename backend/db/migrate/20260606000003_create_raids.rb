class CreateRaids < ActiveRecord::Migration[8.1]
  def change
    create_table :raids do |t|
      t.string :boss, null: false
      t.string :gym_name, null: false
      t.decimal :latitude, precision: 9, scale: 6
      t.decimal :longitude, precision: 9, scale: 6
      t.datetime :starts_at, null: false
      t.integer :capacity, null: false
      t.integer :slots_remaining, null: false
      t.string :status, null: false, default: "draft"
      t.timestamps
    end

    # Capacity invariant carriers (Principle II): enforced at the data layer.
    add_check_constraint :raids, "capacity > 0", name: "raids_capacity_positive"
    add_check_constraint :raids, "slots_remaining >= 0", name: "raids_slots_remaining_non_negative"
    add_check_constraint :raids, "slots_remaining <= capacity", name: "raids_slots_remaining_within_capacity"
    add_index :raids, :status
  end
end
