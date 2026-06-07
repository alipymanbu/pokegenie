require "rails_helper"

RSpec.describe "Elastic encounters", type: :integration do
  def create_encounter(room_size:, status: "published")
    Encounter.create!(boss: "Mewtwo", label: "Central Park", starts_at: 1.hour.from_now,
                      room_size: room_size, status: status)
  end

  def assigned_room_id(enc, trainer)
    QueueRedis.with { |r| r.get(QueueConfig.enc_assignment_key(enc.id, trainer.id)) }
  end

  def room_holds_count(room)
    QueueRedis.with { |r| r.zcard(QueueConfig.room_holds_key(room.id)) }
  end

  it "spawns rooms elastically and assigns everyone — no rejection (FE-002/004, SC-E1/E2)" do
    enc = create_encounter(room_size: 20)
    trainers = create_trainers(50)
    trainers.each { |t| Encounters::Join.call(encounter: enc, trainer: t) }

    Encounters::AdmitBatch.call(encounter: enc) # default batch (50) admits all

    rooms = enc.rooms.order(:room_number)
    expect(rooms.count).to eq(3)                                   # ceil(50/20) = 3
    expect(rooms.map { |r| room_holds_count(r) }).to eq([ 20, 20, 10 ])
    expect(trainers.count { |t| assigned_room_id(enc, t) }).to eq(50) # everyone placed
  end

  it "assigns in FIFO order — the first room gets the earliest joiners" do
    enc = create_encounter(room_size: 20)
    trainers = create_trainers(25)
    trainers.each { |t| Encounters::Join.call(encounter: enc, trainer: t) }

    Encounters::AdmitBatch.call(encounter: enc)

    room1 = enc.rooms.find_by(room_number: 1)
    trainers.first(20).each { |t| expect(assigned_room_id(enc, t)).to eq(room1.id.to_s) }
    room2 = enc.rooms.find_by(room_number: 2)
    trainers.last(5).each { |t| expect(assigned_room_id(enc, t)).to eq(room2.id.to_s) }
  end

  it "lets each admitted trainer claim their assigned room, with no room oversold (FE-003)" do
    enc = create_encounter(room_size: 20)
    trainers = create_trainers(50)
    trainers.each { |t| Encounters::Join.call(encounter: enc, trainer: t) }
    Encounters::AdmitBatch.call(encounter: enc)

    trainers.each do |t|
      room = Raid.find(assigned_room_id(enc, t))
      expect(Reservations::Claim.call(raid: room, trainer: t)).to be_ok
    end

    total = Reservation.where(raid_id: enc.rooms.select(:id), status: "confirmed").count
    expect(total).to eq(50)
    enc.rooms.each do |room|
      confirmed = Reservation.where(raid_id: room.id).count
      expect(confirmed).to be <= enc.room_size       # never oversold
      expect(room.reload.slots_remaining).to be >= 0 # CHECK-backed invariant holds
    end
  end

  it "reports state via Position: waiting → admitted(room) → reserved(room)" do
    enc = create_encounter(room_size: 5)
    t = create_trainers(1).first
    Encounters::Join.call(encounter: enc, trainer: t)
    expect(Encounters::Position.call(encounter: enc, trainer_id: t.id).data[:state]).to eq("waiting")

    Encounters::AdmitBatch.call(encounter: enc)
    admitted = Encounters::Position.call(encounter: enc, trainer_id: t.id)
    expect(admitted.data[:state]).to eq("admitted")
    expect(admitted.data[:room_number]).to eq(1)

    room = Raid.find(assigned_room_id(enc, t))
    Reservations::Claim.call(raid: room, trainer: t)
    reserved = Encounters::Position.call(encounter: enc, trainer_id: t.id)
    expect(reserved.data[:state]).to eq("reserved")
    expect(reserved.data[:room_number]).to eq(1)
  end

  it "keeps filling the same open room across multiple admission ticks" do
    enc = create_encounter(room_size: 10)
    trainers = create_trainers(8)
    trainers.each { |t| Encounters::Join.call(encounter: enc, trainer: t) }

    QueueRedis.with { |r| r.set(QueueConfig.enc_admission_rate_key(enc.id), 4) } # 4 per tick
    Encounters::AdmitBatch.call(encounter: enc) # admits 4 → room 1 (4/10)
    Encounters::AdmitBatch.call(encounter: enc) # admits 4 → still room 1 (8/10)

    expect(enc.rooms.count).to eq(1)
    expect(room_holds_count(enc.rooms.first)).to eq(8)
  end

  it "backfills an AFK no-show's freed slot to a later trainer (no new room spawned)" do
    enc = create_encounter(room_size: 3)
    a, b, c = create_trainers(3)
    [ a, b, c ].each { |t| Encounters::Join.call(encounter: enc, trainer: t) }
    Encounters::AdmitBatch.call(encounter: enc) # all 3 → room 1 (3/3)
    room1 = enc.rooms.first
    expect(enc.rooms.count).to eq(1)

    # b and c claim; a goes AFK — simulate its hold lapsing (expired score) + claimable expiring.
    [ b, c ].each { |t| Reservations::Claim.call(raid: Raid.find(assigned_room_id(enc, t)), trainer: t) }
    QueueRedis.with do |r|
      r.zadd(QueueConfig.room_holds_key(room1.id), 1, a.id.to_s) # epoch 1 → pruned as lapsed
      r.del(QueueConfig.claimable_key(room1.id, a.id))
    end

    # A new trainer arrives → should backfill a's freed slot in room 1, not open room 2.
    d = create_trainers(1).first
    Encounters::Join.call(encounter: enc, trainer: d)
    result = Encounters::AdmitBatch.call(encounter: enc)

    expect(enc.rooms.count).to eq(1)                 # no new room
    expect(result[:backfilled]).to eq(1)
    expect(assigned_room_id(enc, d)).to eq(room1.id.to_s)
    expect(Reservations::Claim.call(raid: room1, trainer: d)).to be_ok
    expect(room1.reload.slots_remaining).to eq(0)    # 3 confirmed (b, c, d), room full, no oversell
  end
end
