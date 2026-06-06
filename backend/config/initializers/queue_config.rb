# Tuning parameters for the raid lobby queue (see specs/001-raid-lobby-queue/data-model.md).
# All read from ENV with conservative defaults. The admission default batch is the
# control/data-plane fallback (Principle III): used whenever the deferred coordinator
# has not written admission:rate:{raid}.
module QueueConfig
  RECONNECT_GRACE_SECONDS = ENV.fetch("RECONNECT_GRACE_SECONDS", 120).to_i
  ADMISSION_DEFAULT_BATCH = ENV.fetch("ADMISSION_DEFAULT_BATCH", 50).to_i
  ADMISSION_TICK_MS       = ENV.fetch("ADMISSION_TICK_MS", 1000).to_i
  CLAIM_WINDOW_SECONDS    = ENV.fetch("CLAIM_WINDOW_SECONDS", 120).to_i
  POSITION_PUSH_MS        = ENV.fetch("POSITION_PUSH_MS", 1500).to_i
  POST_START_GRACE_SECONDS = ENV.fetch("POST_START_GRACE_SECONDS", 0).to_i

  module_function

  # Redis key helpers — single source of truth for the keyspace.
  def seq_key(raid_id)            = "seq:#{raid_id}"
  def queue_key(raid_id)          = "queue:#{raid_id}"
  # Per-trainer claim pass: own TTL (CLAIM_WINDOW_SECONDS) so each admitted trainer's window
  # expires independently. Existence == "admitted and may still claim".
  def claimable_key(raid_id, trainer_id) = "claimable:#{raid_id}:#{trainer_id}"
  def token_key(token)            = "token:#{token}"
  def events_channel(raid_id)     = "events:#{raid_id}"
  def admission_rate_key(raid_id) = "admission:rate:#{raid_id}"
  def metric_claims_key(raid_id)    = "metrics:claims:#{raid_id}"
  def metric_conflicts_key(raid_id) = "metrics:conflicts:#{raid_id}"
  def metric_admitted_key(raid_id)  = "metrics:admitted:#{raid_id}"
end
