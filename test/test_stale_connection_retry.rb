# frozen_string_literal: true

require 'stringio'
require 'test_helper'

# A pooled connection can be closed by the peer between being handed out and
# being written to. That race is replayed once, under strict guards.
class TestStaleConnectionRetry < Minitest::Test
  def test_request_is_replayed_when_a_reused_connection_was_dropped
    port = start_server_that_drops_reused_connections

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)

    assert_equal('Hello There', MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/").body.to_s)

    # The pooled connection is dead, but it looked fine when it was handed out.
    assert_equal('Hello There', MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/").body.to_s)
  end

  def test_a_fresh_connection_is_not_replayed
    port = start_server_that_drops_every_connection

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)

    # Nothing is reused here, so the failure is a real fault rather than a race.
    assert_raises(MintHttp::ConnectionError) do
      MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/")
    end
  end

  def test_request_carrying_files_is_never_replayed
    port, received = start_server_that_drops_reused_connections(record: true)

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)
    MintHttp.use_pool(pool).get("http://127.0.0.1:#{port}/")

    # Net::HTTP re-encodes a multipart body from the source IOs on every exec,
    # and they sit at EOF after the first attempt. Replaying would ship a
    # truncated body with a matching Content-Length and the server would take it.
    assert_raises(MintHttp::ConnectionError) do
      MintHttp
        .use_pool(pool)
        .as_multipart
        .with_file('f', StringIO.new('X' * 64), 'a.txt', 'text/plain')
        .put("http://127.0.0.1:#{port}/upload")
    end

    lengths = []
    lengths << received.pop until received.empty?
    assert_equal(1, lengths.length, 'the multipart body must be sent exactly once')
  end

  private

  # Answers the first request on a connection, then closes without replying to
  # the second -- the peer vanishing between our health check and the write.
  def start_server_that_drops_reused_connections(record: false)
    server = TCPServer.new('127.0.0.1', 0)
    received = Queue.new

    Thread.new do
      loop do
        client = server.accept

        Thread.new do
          begin
            seen = 0
            loop do
              headers = read_headers(client)
              seen += 1

              if seen == 1
                client.write(http_response)
                client.flush
                next
              end

              received << headers[/content-length:\s*(\d+)/i, 1].to_i if record
              client.close
              break
            end
          rescue StandardError
            nil
          end
        end
      end
    end

    sleep(0.5)
    record ? [server.addr[1], received] : server.addr[1]
  end

  def start_server_that_drops_every_connection
    server = TCPServer.new('127.0.0.1', 0)

    Thread.new do
      loop do
        client = server.accept
        Thread.new do
          begin
            read_headers(client)
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

  def read_headers(client)
    headers = +''
    headers << client.readpartial(1) until headers.end_with?("\r\n\r\n")
    headers
  end

  def http_response
    "HTTP/1.1 200 OK\r\nContent-Type: plain/test\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nHello There"
  end
end
