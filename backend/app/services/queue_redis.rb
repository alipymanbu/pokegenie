# Pooled Redis access shared by API request threads, SSE (ActionController::Live) threads,
# and the standalone admission worker. SSE handlers hold a connection for the life of the
# stream (for SUBSCRIBE), so callers that subscribe should check out a dedicated connection.
require "redis"
require "connection_pool"

module QueueRedis
  REDIS_URL = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

  POOL = ConnectionPool.new(size: ENV.fetch("REDIS_POOL_SIZE", 25).to_i, timeout: 5) do
    Redis.new(url: REDIS_URL)
  end

  module_function

  # Yields a pooled Redis connection.
  def with(&block)
    POOL.with(&block)
  end

  # A standalone (non-pooled) connection — use for blocking SUBSCRIBE in SSE streams,
  # since a subscribed connection cannot be returned to the shared pool mid-subscription.
  def dedicated
    Redis.new(url: REDIS_URL)
  end
end
