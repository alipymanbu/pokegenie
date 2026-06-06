require "rails_helper"

RSpec.describe Reservations::Claim do
  let(:raid) { create_raid(capacity: 3) }
  let(:trainer) { create_trainers(1).first }

  before { admit!(raid, trainer) }

  it "confirms a reservation and decrements the slot count once" do
    result = described_class.call(raid: raid, trainer: trainer)

    expect(result).to be_ok
    expect(result.code).to eq(:created)
    expect(result.data[:reservation].status).to eq("confirmed")
    expect(raid.reload.slots_remaining).to eq(2)
    expect(confirmed_count(raid)).to eq(1)
  end

  it "is idempotent: repeating the same claim yields one reservation, one decrement (FR-008, SC-005)" do
    first = described_class.call(raid: raid, trainer: trainer)
    # re-admit because a successful claim clears the admitted flag
    admit!(raid, trainer)
    second = described_class.call(raid: raid, trainer: trainer)

    expect(first).to be_ok
    expect(second).to be_ok
    expect(second.data[:idempotent]).to be(true)
    expect(first.data[:reservation].id).to eq(second.data[:reservation].id)
    expect(confirmed_count(raid)).to eq(1)
    expect(raid.reload.slots_remaining).to eq(2) # decremented exactly once
  end

  it "rejects with :raid_full when no slots remain and creates no reservation (FR-009)" do
    full_raid = create_raid(capacity: 1)
    a, b = create_trainers(2)
    admit!(full_raid, a)
    admit!(full_raid, b)

    expect(described_class.call(raid: full_raid, trainer: a)).to be_ok
    result = described_class.call(raid: full_raid, trainer: b)

    expect(result).not_to be_ok
    expect(result.code).to eq(:raid_full)
    expect(confirmed_count(full_raid)).to eq(1)
    expect(full_raid.reload.slots_remaining).to eq(0)
  end

  it "rejects with :not_admitted when the trainer was never admitted" do
    other = create_trainers(1).first # not admitted
    result = described_class.call(raid: raid, trainer: other)

    expect(result).not_to be_ok
    expect(result.code).to eq(:not_admitted)
    expect(confirmed_count(raid)).to eq(0)
  end
end
