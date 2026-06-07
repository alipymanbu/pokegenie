class AddEncounterToRaids < ActiveRecord::Migration[8.1]
  def change
    # A Raid with encounter_id set is a "room" of that encounter; null = standalone raid (feature 001).
    add_reference :raids, :encounter, foreign_key: { on_delete: :restrict }, null: true
    add_column :raids, :room_number, :integer
  end
end
