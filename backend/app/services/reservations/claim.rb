module Reservations
  # The capacity invariant (Principle II — NON-NEGOTIABLE).
  #
  # A single Postgres transaction:
  #   1. INSERT ... ON CONFLICT DO NOTHING  → idempotency (FR-008). If the row already
  #      existed, the claim is a replay: succeed WITHOUT decrementing.
  #   2. Guarded atomic decrement:
  #        UPDATE raids SET slots_remaining = slots_remaining - 1
  #        WHERE id = ? AND slots_remaining > 0
  #      The row lock serializes concurrent last-slot claims; the predicate fails the loser.
  #      0 rows updated ⇒ raid is full ⇒ ROLLBACK (undoes the insert) ⇒ failure(:raid_full).
  #
  # CHECK (slots_remaining >= 0) is the data-layer backstop; if it ever fires, that is a real
  # oversell attempt and is logged at error severity (Principle VII).
  class Claim
    def self.call(raid:, trainer:)
      new(raid:, trainer:).call
    end

    def initialize(raid:, trainer:)
      @raid = raid
      @trainer = trainer
    end

    def call
      record_metric(QueueConfig.metric_claims_key(@raid.id))

      # Idempotency first (FR-008): a replay of a claim that already succeeded returns the
      # existing reservation — even though the successful claim cleared the admitted flag.
      # This must precede the admitted gate so retries/double-taps don't see :not_admitted.
      existing = find_reservation
      return ServiceResult.success(code: :ok, reservation: existing, idempotent: true) if existing

      # Flow gate: only admitted trainers may make a NEW claim. Capacity is still independently
      # enforced below (defense in depth), so this gate is about fairness, not safety.
      unless admitted?
        return ServiceResult.failure(code: :not_admitted)
      end

      outcome = run_transaction
      case outcome
      when :created
        clear_admitted
        ServiceResult.success(code: :created, reservation: find_reservation)
      when :idempotent
        clear_admitted
        ServiceResult.success(code: :ok, reservation: find_reservation, idempotent: true)
      when :full
        record_metric(QueueConfig.metric_conflicts_key(@raid.id))
        ServiceResult.failure(code: :raid_full)
      end
    end

    private

    def admitted?
      QueueRedis.with { |r| r.exists?(QueueConfig.claimable_key(@raid.id, @trainer.id)) }
    end

    def clear_admitted
      QueueRedis.with { |r| r.del(QueueConfig.claimable_key(@raid.id, @trainer.id)) }
    end

    def run_transaction
      outcome = nil
      ApplicationRecord.transaction do
        inserted = exec(<<~SQL, "claim_insert")
          INSERT INTO reservations (raid_id, trainer_id, status, created_at, updated_at)
          VALUES (#{@raid.id.to_i}, #{@trainer.id.to_i}, 'confirmed', now(), now())
          ON CONFLICT (raid_id, trainer_id) DO NOTHING
          RETURNING id
        SQL

        if inserted.rows.empty?
          outcome = :idempotent # reservation already existed → no decrement
          next
        end

        updated = exec(<<~SQL, "claim_decrement")
          UPDATE raids SET slots_remaining = slots_remaining - 1, updated_at = now()
          WHERE id = #{@raid.id.to_i} AND slots_remaining > 0
          RETURNING slots_remaining
        SQL

        if updated.rows.empty?
          outcome = :full
          raise ActiveRecord::Rollback # undo the just-inserted reservation
        end

        outcome = :created
      end
      outcome
    rescue ActiveRecord::StatementInvalid => e
      # CHECK (slots_remaining >= 0) should make this unreachable; if we get here the
      # data-layer backstop caught a would-be oversell — surface it loudly (Principle VII).
      Rails.logger.error("[OVERSELL ATTEMPT] raid=#{@raid.id} trainer=#{@trainer.id} #{e.class}: #{e.message}")
      :full
    end

    def exec(sql, name)
      ApplicationRecord.connection.exec_query(sql, name)
    end

    def find_reservation
      Reservation.find_by(raid_id: @raid.id, trainer_id: @trainer.id)
    end

    def record_metric(key)
      QueueRedis.with { |r| r.incr(key) }
    rescue => e
      Rails.logger.warn("[metrics] failed to record #{key}: #{e.message}")
    end
  end
end
