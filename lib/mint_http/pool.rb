# frozen_string_literal: true

class MintHttp::Pool
  Waiter = Struct.new(:namespace, :deadline)

  attr_reader :ttl
  attr_reader :idle_ttl
  attr_reader :timeout
  attr_reader :size
  attr_reader :usage_limit
  attr_reader :created_connections
  attr_reader :retry_stale

  def initialize(options = {})
    @mutex = Mutex.new
    @released = ConditionVariable.new

    @ttl = options[:ttl] || 10000
    @idle_ttl = options[:idle_ttl] || 5000
    @timeout = options[:timeout] || 5000

    # Send GET/HEAD/OPTIONS requests (or requests with an Idempotency-Key header) once more
    # on a new connection when a reused connection turns out to be closed by the server
    @retry_stale = options[:retry_stale] || false

    @size = options[:size] || 10
    @usage_limit = options[:usage_limit] || 100
    @created_connections = 0

    @pool = []
    # Threads waiting for a connection, served first come first served
    @waiters = []
    @pid = Process.pid
  end

  def net_factory
    @net_factory ||= MintHttp::NetHttpFactory.new
  end

  def acquire(hostname, port, options = {})
    checkout_entry(hostname, port, options, Thread.current[:mint_http_checkout].equal?(self))
  end

  # Like #acquire (and goes through it), used by MintHttp::Request: connections it leaves
  # checked out because of an interrupt are reclaimed, see PoolEntry#leaked?
  # Thread#[] is fiber-local.
  def checkout(hostname, port, options = {})
    previous = Thread.current[:mint_http_checkout]
    Thread.current[:mint_http_checkout] = self
    acquire(hostname, port, options)
  ensure
    Thread.current[:mint_http_checkout] = previous
  end

  def release(client)
    raise ArgumentError, 'An client is required to be released.' unless client

    Thread.handle_interrupt(Object => :never) do
      discarded = []

      begin
        @mutex.synchronize do
          reset_after_fork_unsafe!

          if (entry = @pool.find { |e| e.matches?(client) })
            entry.release!
          end

          discarded = clean_pool_unsafe!
          @released.broadcast
        end
      ensure
        close_entries(discarded)
      end
    end
  end

  def current_size
    @mutex.synchronize { @pool.length }
  end

  private

  def checkout_entry(hostname, port, options, managed)
    namespace = net_factory.client_namespace(hostname, port, options)
    deadline = time_ms + @timeout
    discarded = []
    waiter = Waiter.new(namespace, deadline)

    begin
      @mutex.synchronize do
        reset_after_fork_unsafe!
        @waiters.reject! { |w| w.deadline <= time_ms }
        @waiters << waiter

        begin
          loop do
            discarded.concat(reclaim_leaked_unsafe!)
            discarded.concat(clean_pool_unsafe!)

            if (client = checkout_unsafe(waiter, hostname, port, options, managed, discarded))
              return client
            end

            remaining = deadline - time_ms
            if remaining <= 0
              raise MintHttp::PoolTimeoutError, "Cannot acquire lock after #{@timeout}ms."
            end

            @released.wait(@mutex, remaining / 1000.0)
          end
        ensure
          @waiters.delete_if { |w| w.equal?(waiter) }
          # Let the next waiter in line take any capacity that is still free
          @released.broadcast if @waiters.any? && spare_capacity_unsafe?
        end
      end
    ensure
      close_entries(discarded)
    end
  end

  # Hands out a connection to the waiter if it is its turn. Waiters are served in arrival
  # order so threads that just released a connection cannot starve earlier waiters:
  # a waiter may reuse an idle connection when no earlier waiter wants the same host, and
  # may open (or evict to make room for) a connection only when it is first in line.
  def checkout_unsafe(waiter, hostname, port, options, managed, discarded)
    # A waiter past its deadline can only be left behind by an interrupt, it is not waiting
    now = time_ms
    ahead = @waiters.take_while { |w| !w.equal?(waiter) }.select { |w| w.deadline > now }

    if ahead.none? { |w| w.namespace == waiter.namespace } &&
      (entry = @pool.find { |e| e.namespace == waiter.namespace && e.available? })
      entry.acquire!(managed)
      return entry.client
    end

    return nil unless ahead.empty?

    # Pool is full but some connections are idle (they belong to other hosts, otherwise
    # one would have been picked above): evict the least recently used.
    if @pool.length >= @size && (idle = @pool.reject(&:acquired).min_by(&:last_used))
      @pool.delete(idle)
      discarded << idle
    end

    return nil if @pool.length >= @size

    client = net_factory.make_client(hostname, port, options)
    append(client, waiter.namespace).acquire!(managed)
    @created_connections += 1

    client
  end

  def spare_capacity_unsafe?
    @pool.length < @size || @pool.any? { |e| !e.acquired }
  end

  def append(client, namespace)
    if @pool.any? { |e| e.matches?(client) }
      raise RuntimeError, "client with id ##{client.object_id} already exists in the pool."
    end

    @pool << (entry = MintHttp::PoolEntry.new(self, client, namespace))
    entry
  end

  def time_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end

  def elapsed(beginning)
    time_ms - beginning
  end

  # Removes expired/unhealthy idle entries and returns them. Closing their sockets is
  # left to the caller so it happens outside the mutex.
  def clean_pool_unsafe!
    to_clean = []

    @pool.delete_if do |e|
      to_clean << e if (should_clean = e.to_clean?)
      should_clean
    end

    to_clean
  end

  # Leaked connections may be mid-request, so they are closed rather than reused.
  def reclaim_leaked_unsafe!
    leaked = []

    @pool.delete_if do |e|
      leaked << e if (should_reclaim = e.leaked?)
      should_reclaim
    end

    leaked
  end

  def clean_pool!
    discarded = @mutex.synchronize { clean_pool_unsafe! }
    close_entries(discarded)
  end

  # Never interrupted: an interrupt here would surface after a connection was already
  # acquired and leak its slot.
  def close_entries(entries)
    return if entries.empty?

    Thread.handle_interrupt(Object => :never) do
      entries.each do |e|
        e.client.finish rescue nil
      end
    end
  end

  # Connections inherited from the parent process share their sockets (and TLS state)
  # with it. Drop them without a TLS shutdown so the parent's connections stay intact.
  def reset_after_fork_unsafe!
    return if @pid == Process.pid

    @pool.each do |e|
      e.client.underlying_tcp_socket&.close rescue nil
    end

    @pool = []
    @waiters = []
    @released = ConditionVariable.new
    @pid = Process.pid
  end
end
