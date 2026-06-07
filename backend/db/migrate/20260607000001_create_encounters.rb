class CreateEncounters < ActiveRecord::Migration[8.1]
  def change
    create_table :encounters do |t|
      t.string :boss, null: false
      t.string :label, null: false       # location / description
      t.datetime :starts_at, null: false
      t.integer :room_size, null: false   # capacity per spawned room
      t.string :status, null: false, default: "draft"
      t.timestamps
    end
    add_check_constraint :encounters, "room_size > 0", name: "encounters_room_size_positive"
    add_index :encounters, :status
  end
end
