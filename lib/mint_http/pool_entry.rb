# frozen_string_literal: true

require 'openssl'

class MintHttp::PoolEntry
  # Everything a socket probe can legitimately raise when the peer is gone.
  # SystemCallError covers the whole Errno family; IOError covers EOFError,
  # a closed stream, and IO::TimeoutError on Ruby 3.2+; OpenSSLError covers
  # the TLS layer failing under us.
  #
  # Deliberately absent:
  #   Timeout::Error -- Rack::Timeout and Timeout.timeout raise it
  #     asynchronously into whatever code is running. Swallowing it here would
  #     quietly defeat the caller's own request timeout.
  #   SocketError, Resolv::ResolvError -- name resolution errors. The probe
  #     touches an already connected socket and resolves nothing.
  #
  # Anything outside this list is a bug in the probe itself and must not be
  # swallowed: answering "unhealthy" forever would stop the pool reusing
  # connections with nothing to show for it.
  PROBE_ERRORS = [IOError, SystemCallError, OpenSSL::OpenSSLError].freeze

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
    @last_used = time_ms
  end

  def available?
    !@acquired && !expired? && healthy?
  end

  # Probing a connection is itself an operation that can fail. A peer that reset
  # the connection makes eof? raise Errno::ECONNRESET rather than return true,
  # and that exception used to escape acquire and release -- surfacing as a
  # ConnectionResetError on a request that had not been sent yet, or replacing an
  # already successful response from inside the ensure block in with_client.
  # Worse, release reaps entries by calling to_clean?, so one reset connection
  # could break cleanup for every other entry in the pool, including entries for
  # unrelated hosts.
  #
  # A connection we cannot successfully probe is a connection we must not reuse,
  # so a failed probe answers false and lets the entry be reaped.
  def healthy?
    socket = client.underlying_tcp_socket
    return false unless socket.is_a?(TCPSocket)
    return false if socket.closed?
    return false if socket.wait_readable(0) && client.buffered_socket.eof?

    true
  rescue *PROBE_ERRORS
    false
  end

  def to_clean?
    (expired? || !healthy?) && !@acquired
  end

  private

  def time_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end
end
