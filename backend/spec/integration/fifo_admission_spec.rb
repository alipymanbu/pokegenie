require "rails_helper"

# Release-blocking (constitution Principle I + SC-002): admission order == join order.
RSpec.describe "FIFO admission", type: :integration do
  it "admits trainers in the exact order they joined" do
    raid = create_raid(capacity: 100)
    trainers = create_trainers(10)

    # Join sequentially in a known order.
    trainers.each { |t| RaidQueue::Join.call(raid: raid, trainer: t) }

    admitted_order = []
    # Admit two at a time and record the order trainers leave the line.
    allow(Admission::Pacing).to receive(:batch_size).and_return(2)
    5.times do
      before_ids = QueueRedis.with { |r| r.zrange(QueueConfig.queue_key(raid.id), 0, -1) }
      RaidQueue::AdmitBatch.call(raid: raid)
      after_ids = QueueRedis.with { |r| r.zrange(QueueConfig.queue_key(raid.id), 0, -1) }
      admitted_order.concat(before_ids - after_ids)
    end

    expect(admitted_order).to eq(trainers.map { |t| t.id.to_s })
  end

  it "gives the first N joiners the reservations when N < contenders" do
    capacity = 3
    raid = create_raid(capacity: capacity)
    trainers = create_trainers(8)
    trainers.each { |t| RaidQueue::Join.call(raid: raid, trainer: t) }

    # Drain the whole line through admission, then each admitted trainer claims in turn.
    allow(Admission::Pacing).to receive(:batch_size).and_return(8)
    RaidQueue::AdmitBatch.call(raid: raid)

    outcomes = trainers.map { |t| [ t, Reservations::Claim.call(raid: raid, trainer: t) ] }
    winners = outcomes.select { |(_, r)| r.ok? }.map { |(t, _)| t }

    expect(winners).to eq(trainers.first(capacity)) # earliest joiners win
  end
end
