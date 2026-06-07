class EnforceOneActiveEncounterPerBoss < ActiveRecord::Migration[8.1]
  # One encounter per Pokémon: queuing for a boss must funnel into that boss's
  # single elastic encounter, never spawn a parallel one. Enforced in Postgres
  # (control plane can't be trusted to dedupe under concurrency).
  def up
    # Collapse any existing duplicate active encounters per boss, keeping the
    # most-active one (most rooms, then earliest) so the live queue survives.
    execute(<<~SQL)
      WITH ranked AS (
        SELECT e.id,
               row_number() OVER (
                 PARTITION BY lower(e.boss)
                 ORDER BY (SELECT count(*) FROM raids r WHERE r.encounter_id = e.id) DESC,
                          e.id ASC
               ) AS rn
        FROM encounters e
        WHERE e.status <> 'closed'
      )
      UPDATE encounters SET status = 'closed', updated_at = now()
      WHERE id IN (SELECT id FROM ranked WHERE rn > 1);
    SQL

    add_index :encounters, "lower(boss)", unique: true,
              where: "status <> 'closed'",
              name: "index_encounters_unique_active_boss"
  end

  def down
    remove_index :encounters, name: "index_encounters_unique_active_boss"
  end
end
