# frozen_string_literal: true

class MintHttp::PoolEntry
  attr_reader :client
  attr_reader :namespace
  attr_reader :acquired
  attr_reader :last_used
  attr_reader :usage
  attr_reader :unhealthy
  attr_reader :managed

  def initialize(pool, client, namespace)
    @pool = pool
    @client = client
    @namespace = namespace
    @acquired = false
    @birth_time = time_ms
    @last_used = time_ms
    @usage = 0
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

  # @param [Boolean] managed checked out by MintHttp::Request, see #leaked?
  def acquire!(managed = false)
    @acquired = true
    @managed = managed
    @owner_thread = Thread.current
    @owner_fiber = Fiber.current
    @last_used = time_ms
    @usage += 1
  end

  def release!
    @acquired = false
    @managed = false
    @owner_thread = nil
    @owner_fiber = nil
  end

  # A connection checked out by MintHttp::Request that its owner can no longer be using:
  # the owner is dead, or it is checking out another connection. That only happens when an
  # interrupt landed in the narrow window between check-out and the request's ensure.
  def leaked?
    return false unless @acquired && @managed

    !@owner_thread.alive? || !@owner_fiber.alive? || @owner_fiber.equal?(Fiber.current)
  end

  def available?
    !@acquired && !expired? && healthy?
  end

  # Checks whether an idle keep-alive connection can be reused. Must never be called
  # on an acquired entry: the socket belongs to another thread mid-request.
  #
  # An idle HTTP/1.1 connection must have nothing to read. Any readable byte means the
  # peer closed (FIN/RST), sent a TLS close_notify / post-handshake record, or left
  # unread response data behind; reusing it would fail or desynchronize responses.
  # The check is non-blocking and never raises.
  def healthy?
    return false if @acquired

    # Interrupts (e.g. Rack::Timeout) are deferred so the probe's rescue cannot swallow them
    Thread.handle_interrupt(Object => :never) { probe }
  end

  def to_clean?
    !@acquired && (expired? || !healthy?)
  end

  private

  def probe
    socket = client.underlying_tcp_socket
    return false unless socket.is_a?(TCPSocket)
    return false if socket.closed?
    return false if client.pending_buffered_bytes?

    socket.recv_nonblock(1, Socket::MSG_PEEK, exception: false) == :wait_readable
  rescue StandardError
    false
  end

  def time_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
