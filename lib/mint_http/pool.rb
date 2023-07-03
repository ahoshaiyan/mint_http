# frozen_string_literal: true

class MintHttp::Pool
  attr_reader :ttl
  attr_reader :idle_ttl
  attr_reader :timeout
  attr_reader :size
  attr_reader :usage_limit

  def initialize(options = {})
    @mutex = Mutex.new

    @ttl = options[:ttl] || 10000
    @idle_ttl = options[:idle_ttl] || 5000
    @timeout = options[:timeout] || 5000

    @size = options[:size] || 10
    @usage_limit = options[:usage_limit] || 100

    @pool = []
  end

  def net_factory
    @net_factory ||= MintHttp::NetHttpFactory.new
  end

  def acquire(hostname, port, options = {})
    namespace = net_factory.client_namespace(hostname, port, options)
    deadline = time_ms + @timeout

    while time_ms < deadline
      @mutex.synchronize do
        if (entry = @pool.find { |e| e.namespace == namespace && e.available? })
          entry.acquire!
          return entry.client
        end

        if @pool.length > 0 && @pool.all? { |e| e.to_clean? }
          clean_pool_unsafe!
        end

        if @pool.length < @size
          client = net_factory.make_client(hostname, port, options)
          entry = append(client, namespace)
          entry.acquire!
          return entry.client
        end
      end

      sleep_time = (deadline - time_ms) / 2
      sleep_time = [sleep_time, 100].max
      sleep_time = sleep_time / 1000.0

      sleep(sleep_time)
    end

    raise RuntimeError, "Cannot acquire lock after #{@timeout}ms."
  end

  def release(client)
    raise ArgumentError, 'An client is required to be released.' unless client

    @mutex.synchronize do
      if (entry = @pool.find { |e| e.matches?(client) })
        entry.release!
      end

      clean_pool_unsafe!
    end
  end

  private

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

  def clean_pool_unsafe!
    to_clean = []

    @pool.delete_if do |e|
      to_clean << e if (should_clean = e.to_clean?)
      should_clean
    end

    to_clean.each do |e|
      e.client.finish rescue nil
    end
  end

  def clean_pool!
    @mutex.synchronize do
      clean_pool_unsafe!
    end
  end
end
