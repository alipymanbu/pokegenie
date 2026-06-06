require "rails_helper"

RSpec.describe "Reconnect & grace window", type: :integration do
  # Simulate the presence heartbeat lapsing (trainer gone past the grace window).
  def drop_presence!(raid, trainer)
    QueueRedis.with { |r| r.del(QueueConfig.presence_key(raid.id, trainer.id)) }
  end

  describe RaidQueue::Join do
    it "keeps the original position when reconnecting within the grace window (FR-010)" do
      raid = create_raid(capacity: 100)
      a, b, c = create_trainers(3)
      [ a, b, c ].each { |t| described_class.call(raid: raid, trainer: t) }

      # b is still present (heartbeat alive) → re-join keeps position 2.
      again = described_class.call(raid: raid, trainer: b)
      expect(again.data[:position]).to eq(2)
      expect(again.data[:depth]).to eq(3)
    end

    it "sends a lapsed trainer to the back of the line (FR-014)" do
      raid = create_raid(capacity: 100)
      a, b, c = create_trainers(3)
      [ a, b, c ].each { |t| described_class.call(raid: raid, trainer: t) }

      drop_presence!(raid, a) # a was gone longer than the grace window
      again = described_class.call(raid: raid, trainer: a)

      expect(again.data[:position]).to eq(3) # behind b and c now
    end
  end

  describe RaidQueue::Reconnect do
    it "restores a within-grace trainer to their original position" do
      raid = create_raid(capacity: 100)
      a, b = create_trainers(2)
      described_class_join(raid, a)
      token_b = described_class_join(raid, b)

      result = RaidQueue::Reconnect.call(raid: raid, token: token_b)

      expect(result).to be_ok
      expect(result.data[:state]).to eq("waiting")
      expect(result.data[:position]).to eq(2)
    end

    it "restores the queue entry at its original score if it was dropped" do
      raid = create_raid(capacity: 100)
      a = create_trainers(1).first
      token = described_class_join(raid, a)
      # Simulate the entry having been evicted while the token is still valid.
      QueueRedis.with { |r| r.zrem(QueueConfig.queue_key(raid.id), a.id.to_s) }

      result = RaidQueue::Reconnect.call(raid: raid, token: token)

      expect(result).to be_ok
      expect(result.data[:state]).to eq("waiting")
      expect(result.data[:position]).to eq(1)
    end

    it "reports an existing reservation as 'reserved' (FR-011: survives disconnect)" do
      raid = create_raid(capacity: 5)
      a = create_trainers(1).first
      token = described_class_join(raid, a)
      admit!(raid, a)
      Reservations::Claim.call(raid: raid, trainer: a)

      result = RaidQueue::Reconnect.call(raid: raid, token: token)

      expect(result).to be_ok
      expect(result.data[:state]).to eq("reserved")
      expect(result.data[:reservation]).to be_present
    end

    it "fails as :expired when the token is gone (→ caller rejoins at the back)" do
      raid = create_raid(capacity: 5)
      result = RaidQueue::Reconnect.call(raid: raid, token: "missing-token")
      expect(result).not_to be_ok
      expect(result.code).to eq(:expired)
    end
  end

  # Helper: join and return the minted token.
  def described_class_join(raid, trainer)
    RaidQueue::Join.call(raid: raid, trainer: trainer).data[:token]
  end
end
