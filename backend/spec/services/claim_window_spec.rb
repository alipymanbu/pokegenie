require "rails_helper"

# Per-trainer claim window: each admitted trainer gets an independent TTL pass.
RSpec.describe "Claim window", type: :integration do
  it "AdmitBatch grants each admitted trainer a claim pass with a TTL" do
    raid = create_raid(capacity: 5)
    trainers = create_trainers(3)
    trainers.each { |t| RaidQueue::Join.call(raid: raid, trainer: t) }

    allow(Admission::Pacing).to receive(:batch_size).and_return(3)
    RaidQueue::AdmitBatch.call(raid: raid)

    trainers.each do |t|
      ttl = QueueRedis.with { |r| r.ttl(QueueConfig.claimable_key(raid.id, t.id)) }
      expect(ttl).to be_between(1, QueueConfig::CLAIM_WINDOW_SECONDS)
    end
  end

  it "Position reports remaining claim seconds while admitted" do
    raid = create_raid(capacity: 5)
    trainer = create_trainers(1).first
    admit!(raid, trainer, ttl: 90)

    result = RaidQueue::Position.call(raid_id: raid.id, trainer_id: trainer.id)

    expect(result).to be_ok
    expect(result.data[:state]).to eq("admitted")
    expect(result.data[:claim_seconds_remaining]).to be_between(1, 90)
  end

  it "rejects a claim once the window has lapsed, consuming no slot" do
    raid = create_raid(capacity: 5)
    trainer = create_trainers(1).first
    admit!(raid, trainer)
    expire_claim_pass!(raid, trainer) # window lapsed without claiming

    result = Reservations::Claim.call(raid: raid, trainer: trainer)

    expect(result).not_to be_ok
    expect(result.code).to eq(:not_admitted)
    expect(confirmed_count(raid)).to eq(0)
    expect(raid.reload.slots_remaining).to eq(5) # slot untouched — nothing was held
  end

  it "an expired pass leaves the slot free for the next admitted trainer" do
    raid = create_raid(capacity: 1)
    a, b = create_trainers(2)
    admit!(raid, a)
    expire_claim_pass!(raid, a) # a never claims; window lapses
    admit!(raid, b)

    expect(Reservations::Claim.call(raid: raid, trainer: a).code).to eq(:not_admitted)
    expect(Reservations::Claim.call(raid: raid, trainer: b)).to be_ok
    expect(raid.reload.slots_remaining).to eq(0)
  end
end
