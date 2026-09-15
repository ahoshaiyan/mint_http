# frozen_string_literal: true

require 'test_helper'

# Probing a pooled connection is itself an operation that can fail. These cover
# PoolEntry#healthy? answering instead of raising, and the blast radius that had
# when it did raise.
class TestPoolHealthCheck < Minitest::Test
  def test_reset_connection_is_reported_unhealthy_instead_of_raising
    port = start_reset_after_response_server

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)
    MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/")

    entry = pool_entries(pool).first
    refute_nil(entry)

    # Let the peer send the RST. eof? raises Errno::ECONNRESET on such a socket.
    sleep(1)

    healthy = nil
    assert_silent_of_error { healthy = entry.healthy? }
    refute(healthy, 'a reset connection must be reported unhealthy')
    assert(entry.to_clean?, 'a reset connection must be reapable')
  end

  def test_request_succeeds_when_pooled_connection_was_reset_by_peer
    port = start_reset_after_response_server

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)

    assert_equal('Hello There', MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/").body.to_s)
    sleep(1)

    # Used to raise MintHttp::ConnectionResetError straight out of Pool#acquire.
    assert_equal('Hello There', MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/").body.to_s)
  end

  def test_dead_connection_does_not_fail_requests_to_another_host
    dead_port = start_reset_after_response_server
    live_port = start_keep_alive_server

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)

    # Poison the pool with a connection the peer is about to reset.
    MintHttp.use_pool(pool).get("http://127.0.0.1:#{dead_port}/")
    sleep(1)

    # A different namespace entirely. Pool#acquire used to walk every entry and
    # raise from the dead one before it ever looked at this host.
    response = MintHttp.use_pool(pool).get("http://127.0.0.1:#{live_port}/")
    assert_equal('Hello There', response.body.to_s)
  end

  def test_probe_bugs_are_not_swallowed
    entry = MintHttp::PoolEntry.allocate
    entry.define_singleton_method(:client) { raise NoMethodError, 'broken probe' }

    # Only socket faults answer false. A broken probe must surface, otherwise the
    # pool silently stops reusing connections with nothing to show for it.
    assert_raises(NoMethodError) { entry.healthy? }
  end

  private

  def pool_entries(pool)
    pool.instance_variable_get(:@pool)
  end

  def assert_silent_of_error
    yield
  rescue StandardError => e
    flunk("expected no error, got #{e.class}: #{e.message}")
  end

  # Answers one request, then resets the connection rather than closing it
  # cleanly, so the peer sees an RST instead of a FIN.
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

  def http_response
    "HTTP/1.1 200 OK\r\nContent-Type: plain/test\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nHello There"
  end
end
