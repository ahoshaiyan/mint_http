# frozen_string_literal: true

class MintHttp::PoolEntry
  attr_reader :client
  attr_reader :namespace
  attr_reader :acquired
  attr_reader :last_used
  attr_reader :usage
  attr_reader :unhealthy

  def initialize(pool, client, namespace)
    @pool = pool
    @client = client
    @namespace = namespace
    @acquired = false
    @birth_time = time_ms
    @last_used = time_ms
    @usage = 0
    @unhealthy = false
  end

  def matches?(other)
    @client.object_id == other.object_id
  end

  def ttl_reached?
    (time_ms - @birth_time) > @pool.ttl
  end

  def idle_ttl_reached?
    (time_ms - @last_used) > @pool.idle_ttl
  end

  def usage_reached?
    @usage >= @pool.usage_limit
  end

  def expired?
    idle_ttl_reached? || ttl_reached? || usage_reached?
  end

  def acquire!
    @acquired = true
    @last_used = time_ms
    @usage += 1
  end

  def release!
    @acquired = false
  end

  def available?
    !@acquired && !expired? && !@unhealthy
  end

  def healthy?
    # TODO: add health check
    healthy = true
    @unhealthy = !healthy
    healthy
  end

  def to_clean?
    (expired? || @unhealthy) && !@acquired
  end

  private

  def time_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
