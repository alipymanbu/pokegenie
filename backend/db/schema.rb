# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_07_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "encounters", force: :cascade do |t|
    t.string "boss", null: false
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.integer "room_size", null: false
    t.datetime "starts_at", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_encounters_on_status"
    t.check_constraint "room_size > 0", name: "encounters_room_size_positive"
  end

  create_table "raids", force: :cascade do |t|
    t.string "boss", null: false
    t.integer "capacity", null: false
    t.datetime "created_at", null: false
    t.bigint "encounter_id"
    t.string "gym_name", null: false
    t.decimal "latitude", precision: 9, scale: 6
    t.decimal "longitude", precision: 9, scale: 6
    t.integer "room_number"
    t.integer "slots_remaining", null: false
    t.datetime "starts_at", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["encounter_id"], name: "index_raids_on_encounter_id"
    t.index ["status"], name: "index_raids_on_status"
    t.check_constraint "capacity > 0", name: "raids_capacity_positive"
    t.check_constraint "slots_remaining <= capacity", name: "raids_slots_remaining_within_capacity"
    t.check_constraint "slots_remaining >= 0", name: "raids_slots_remaining_non_negative"
  end

  create_table "reservations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "raid_id", null: false
    t.string "status", default: "confirmed", null: false
    t.bigint "trainer_id", null: false
    t.datetime "updated_at", null: false
    t.index ["raid_id", "trainer_id"], name: "index_reservations_unique_trainer_per_raid", unique: true
    t.index ["raid_id"], name: "index_reservations_on_raid_id"
    t.index ["trainer_id"], name: "index_reservations_on_trainer_id"
  end

  create_table "trainers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.citext "handle", null: false
    t.datetime "updated_at", null: false
    t.index ["handle"], name: "index_trainers_on_handle", unique: true
  end

  add_foreign_key "raids", "encounters", on_delete: :restrict
  add_foreign_key "reservations", "raids", on_delete: :restrict
  add_foreign_key "reservations", "trainers", on_delete: :restrict
end
