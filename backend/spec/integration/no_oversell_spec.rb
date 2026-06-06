require "rails_helper"

# Release-blocking (constitution Principle II + SC-001): the capacity invariant under contention.
RSpec.describe "No oversell under concurrent claims", type: :integration do
  it "admits exactly `capacity` reservations when many more trainers claim at once" do
    capacity = 5
    contenders = 40
    raid = create_raid(capacity: capacity)
    trainers = create_trainers(contenders)
    trainers.each { |t| admit!(raid, t) }

    results = run_concurrently(contenders) do |i|
      Reservations::Claim.call(raid: raid, trainer: trainers[i])
    end

    successes = results.count { |r| r.ok? }
    fulls     = results.count { |r| !r.ok? && r.code == :raid_full }

    expect(successes).to eq(capacity)            # exactly capacity won
    expect(fulls).to eq(contenders - capacity)   # everyone else got "raid full"
    expect(confirmed_count(raid)).to eq(capacity)
    expect(raid.reload.slots_remaining).to eq(0) # never negative — zero oversell
  end

  it "the last single slot is won by exactly one of many simultaneous claimers" do
    raid = create_raid(capacity: 1)
    trainers = create_trainers(25)
    trainers.each { |t| admit!(raid, t) }

    results = run_concurrently(25) do |i|
      Reservations::Claim.call(raid: raid, trainer: trainers[i])
    end

    expect(results.count(&:ok?)).to eq(1)
    expect(confirmed_count(raid)).to eq(1)
    expect(raid.reload.slots_remaining).to eq(0)
  end
end
