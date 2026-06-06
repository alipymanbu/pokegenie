require "rails_helper"

# Control plane / data plane separation (Principle III, FR-015, SC-006): admission must keep
# working at a safe default when the admission-pacing coordinator hasn't written a rate (or
# wrote garbage), and the claim path must remain correct regardless.
RSpec.describe "Coordinator down / pacing fallback", type: :integration do
  it "uses the default batch size when no admission rate is set" do
    raid = create_raid(capacity: 100)
    QueueRedis.with { |r| r.del(QueueConfig.admission_rate_key(raid.id)) }

    expect(Admission::Pacing.batch_size(raid.id)).to eq(QueueConfig::ADMISSION_DEFAULT_BATCH)
  end

  it "falls back to the default when the coordinator wrote a non-positive/garbage value" do
    raid = create_raid(capacity: 100)
    QueueRedis.with { |r| r.set(QueueConfig.admission_rate_key(raid.id), "0") }
    expect(Admission::Pacing.batch_size(raid.id)).to eq(QueueConfig::ADMISSION_DEFAULT_BATCH)

    QueueRedis.with { |r| r.set(QueueConfig.admission_rate_key(raid.id), "not-a-number") }
    expect(Admission::Pacing.batch_size(raid.id)).to eq(QueueConfig::ADMISSION_DEFAULT_BATCH)
  end

  it "admits and confirms correctly with the coordinator absent" do
    raid = create_raid(capacity: 3)
    trainers = create_trainers(10)
    trainers.each { |t| RaidQueue::Join.call(raid: raid, trainer: t) }
    QueueRedis.with { |r| r.del(QueueConfig.admission_rate_key(raid.id)) } # no coordinator

    RaidQueue::AdmitBatch.call(raid: raid) # default batch (50) > queue, admits all 10

    winners = trainers.select { |t| Reservations::Claim.call(raid: raid, trainer: t).ok? }
    expect(winners).to eq(trainers.first(3)) # capacity respected, FIFO preserved
    expect(raid.reload.slots_remaining).to eq(0)
  end
end
