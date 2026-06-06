class CreateTrainers < ActiveRecord::Migration[8.1]
  def change
    create_table :trainers do |t|
      t.citext :handle, null: false
      t.timestamps
    end
    add_index :trainers, :handle, unique: true
  end
end
