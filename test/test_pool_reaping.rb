# frozen_string_literal: true

require 'test_helper'

# Cleanup used to run only when every entry in the pool was reapable, and idle
# time was measured from acquire rather than release.
class TestPoolReaping < Minitest::Test
  def test_full_pool_reaps_dead_entries_while_another_is_still_usable
    live_port = start_keep_alive_server
    dead_port = start_reset_after_response_server
    other_port = start_keep_alive_server

    pool = MintHttp::Pool.new(size: 2, timeout: 1000, ttl: 30_000, idle_ttl: 30_000)

    MintHttp.use_pool(pool).get("http://127.0.0.1:#{live_port}/")
    MintHttp.use_pool(pool).get("http://127.0.0.1:#{dead_port}/")
    assert_equal(2, pool.current_size, 'pool should be full')

    # Only one of the two entries goes bad. The other is healthy and idle.
    sleep(1)

    # A third namespace needs a slot. Reaping used to require that *every* entry
    # was reapable, so the healthy idle entry blocked removal of the dead one and
    # acquire slept until :timeout.
    response = MintHttp.use_pool(pool).get("http://127.0.0.1:#{other_port}/")
    assert_equal('Hello There', response.body.to_s)
  end

  def test_idle_time_is_measured_from_release_not_acquire
    entry = MintHttp::PoolEntry.new(
      MintHttp::Pool.new,
      Net::HTTP.new('127.0.0.1', 1),
      'namespace',
    )

    entry.acquire!
    acquired_at = entry.last_used

    # Stands in for a request that takes a while to come back.
    sleep(0.05)
    entry.release!

    assert_operator(
      entry.last_used, :>, acquired_at,
      'idle time must start when the connection is returned, not when it is taken'
    )
  end

  def test_pool_exhaustion_raises_a_mint_http_error
    port = start_slow_server(2)
    pool = MintHttp::Pool.new(size: 1, timeout: 500, ttl: 30_000, idle_ttl: 30_000)

    # Occupy the pool's only slot for longer than another caller will wait.
    worker = Thread.new { MintHttp.use_pool(pool).timeout(5, 5, 5).get("http://127.0.0.1:#{port}/") }
    sleep(0.5)

    # Used to raise a bare RuntimeError, which no rescue MintHttp:: would catch.
    error = assert_raises(MintHttp::PoolTimeoutError) do
      MintHttp.use_pool(pool).timeout(5, 5, 5).get("http://127.0.0.1:#{port}/")
    end
    assert_kind_of(MintHttp::Error, error)

    worker.join
  end

  private

  def start_slow_server(delay)
    server = TCPServer.new('127.0.0.1', 0)

    Thread.new do
      loop do
        client = server.accept

        Thread.new do
          begin
            loop do
              client.gets
              sleep(delay)
              client.write(http_response)
              client.flush
            end
          rescue StandardError
            nil
          end
        end
      end
    end

    sleep(0.5)
    server.addr[1]
  end

  def start_keep_alive_server
    server = TCPServer.new('127.0.0.1', 0)

    Thread.new do
      loop do
        client = server.accept

        Thread.new do
          begin
            loop do
              client.gets
              client.write(http_response)
              client.flush
            end
          rescue StandardError
            nil
          end
        end
      end
    end

    sleep(0.5)
    server.addr[1]
  end

  def start_reset_after_response_server
    server = TCPServer.new('127.0.0.1', 0)

    Thread.new do
      loop do
        client = server.accept

        Thread.new do
          begin
            client.gets
            client.write(http_response)
            client.flush
            sleep(0.3)
            client.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack('ii'))
            client.close
          rescue StandardError
            nil
          end
        end
      end
    end

    sleep(0.5)
    server.addr[1]
  end

  def http_response
    "HTTP/1.1 200 OK\r\nContent-Type: plain/test\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nHello There"
  end
end
