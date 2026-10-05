# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'timeout'

# Regression tests for connection reuse, pool and logging bugs that made successful
# calls fail, hang, or receive another request's response.
class TestReliability < Minitest::Test
  def setup
    @servers = []
  end

  def teardown
    @servers.each { |s| s.close rescue nil }
  end

  # Starts a server on an ephemeral port; the handler is called once per connection.
  def serve(&handler)
    server = TCPServer.new('127.0.0.1', 0)
    @servers << server

    Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          handler.call(c)
        rescue StandardError
          nil
        ensure
          c.close rescue nil
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    "http://127.0.0.1:#{server.addr[1]}"
  end

  def read_request(client)
    head = +''
    while (line = client.gets) && line != "\r\n"
      head << line
    end
    return nil unless line

    length = head[/content-length:\s*(\d+)/i, 1].to_i
    [head, length > 0 ? client.read(length) : '']
  end

  def respond(client, body, headers = {})
    headers = { 'Content-Type' => 'text/plain', 'Content-Length' => body.bytesize }.merge(headers)
    client.write("HTTP/1.1 200 OK\r\n#{headers.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n")
    client.write(body)
  end

  # Keep-alive server that echoes the request path, sleeping `?sleep=` seconds first.
  def echo_server
    serve do |c|
      while (request = read_request(c))
        path = request[0][/\A\S+ (\S+)/, 1]
        delay = path[/sleep=([\d.]+)/, 1].to_f
        sleep(delay) if delay > 0
        respond(c, path.sub(/\?.*/, ''))
      end
    end
  end

  def test_health_check_never_touches_a_connection_in_use
    client = Object.new
    def client.underlying_tcp_socket = raise('socket of an acquired connection was probed')

    entry = MintHttp::PoolEntry.new(MintHttp::Pool.new, client, 'ns')
    entry.acquire!

    refute entry.to_clean?
    refute entry.available?
  end

  def test_concurrent_requests_on_a_shared_pool_do_not_stall
    url = echo_server
    pool = MintHttp::Pool.new(size: 4)
    errors = Queue.new
    slowest = 0.0

    threads = 8.times.map do |t|
      Thread.new do
        25.times do |i|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          body = MintHttp.use_pool(pool).timeout(2, 2, 2).get("#{url}/t#{t}-#{i}").body
          errors << "t#{t}-#{i} got #{body}" unless body == "/t#{t}-#{i}"
          slowest = [slowest, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started].max
        rescue StandardError => e
          errors << "t#{t}-#{i} #{e.class}: #{e.message}"
        end
      end
    end
    threads.each(&:join)

    assert_empty Array.new(errors.size) { errors.pop }
    assert_operator slowest, :<, 2.0
  end

  def test_requests_respect_the_callers_interrupt_mask
    url = echo_server
    pool = MintHttp::Pool.new
    fake_timeout = Class.new(StandardError)
    result = nil

    worker = Thread.new do
      Thread.handle_interrupt(fake_timeout => :never) do
        result = MintHttp.use_pool(pool).get("#{url}/capture?sleep=0.3").body
      end
    rescue fake_timeout
      result = "#{result} then interrupted"
    end

    sleep(0.1)
    worker.raise(fake_timeout)
    worker.join

    assert_equal '/capture then interrupted', result
  end

  def test_pool_reclaims_connections_leaked_by_their_owner
    pool = MintHttp::Pool.new(size: 1, timeout: 200)
    pool.checkout('127.0.0.1', 1) # never released, e.g. interrupted right after checkout
    pool.checkout('127.0.0.1', 1)
    assert_equal 2, pool.created_connections

    pool = MintHttp::Pool.new(size: 1, timeout: 200)
    Thread.new { pool.checkout('127.0.0.1', 1) }.join # owner thread died
    pool.checkout('127.0.0.1', 1)
    assert_equal 2, pool.created_connections

    pool = MintHttp::Pool.new(size: 1, timeout: 200)
    pool.acquire('127.0.0.1', 1) # direct acquire is not reclaimed
    assert_raises(MintHttp::PoolTimeoutError) { pool.acquire('127.0.0.1', 1) }
  end

  def test_interrupted_request_does_not_hand_its_response_to_the_next_request
    url = echo_server
    pool = MintHttp::Pool.new

    assert_equal '/warmup', MintHttp.use_pool(pool).get("#{url}/warmup").body

    assert_raises(Timeout::Error) do
      Timeout.timeout(0.2) { MintHttp.use_pool(pool).get("#{url}/slow-a?sleep=0.5") }
    end

    sleep(0.6)
    assert_equal '/b', MintHttp.use_pool(pool).get("#{url}/b").body
    assert_equal '/c', MintHttp.use_pool(pool).get("#{url}/c").body
  end

  def test_interrupted_requests_do_not_leak_pool_slots
    url = echo_server
    pool = MintHttp::Pool.new(size: 2, timeout: 500)

    20.times do
      Timeout.timeout(rand * 0.01) { MintHttp.use_pool(pool).get("#{url}/x?sleep=0.05") }
    rescue Timeout::Error
      nil
    end

    assert_equal '/ok', MintHttp.use_pool(pool).get("#{url}/ok").body
  end

  def test_unread_bytes_on_an_idle_connection_discard_it
    url = serve do |c|
      while (request = read_request(c))
        path = request[0][/\A\S+ (\S+)/, 1]
        respond(c, path)
        c.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nstale") if path == '/first'
      end
    end
    pool = MintHttp::Pool.new

    assert_equal '/first', MintHttp.use_pool(pool).get("#{url}/first").body
    sleep(0.1)
    assert_equal '/second', MintHttp.use_pool(pool).get("#{url}/second").body
    assert_equal 2, pool.created_connections
  end

  def test_pool_evicts_idle_connections_of_other_hosts
    url_a = echo_server
    url_b = echo_server
    pool = MintHttp::Pool.new(size: 1, idle_ttl: 60_000, timeout: 2000)

    MintHttp.use_pool(pool).get("#{url_a}/a")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal '/b', MintHttp.use_pool(pool).get("#{url_b}/b").body
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
    assert_equal 1, pool.current_size
  end

  def test_pool_timeout_is_still_a_runtime_error
    pool = MintHttp::Pool.new(size: 1, timeout: 200)
    pool.acquire('127.0.0.1', 1)

    error = assert_raises(MintHttp::PoolTimeoutError) { pool.acquire('127.0.0.1', 1) }
    assert_kind_of RuntimeError, error
    assert_equal 'Cannot acquire lock after 200ms.', error.message
  end

  def test_timeout_interrupts_a_request_waiting_for_the_pool
    url = echo_server
    pool = MintHttp::Pool.new(size: 1, timeout: 5000)
    pool.acquire('127.0.0.1', 1) # unrelated host holding the only slot... evicted only when idle

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Timeout::Error) { Timeout.timeout(0.2) { MintHttp.use_pool(pool).get("#{url}/x") } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  end

  def test_waiter_is_woken_up_as_soon_as_a_connection_is_released
    pool = MintHttp::Pool.new(size: 1, timeout: 5000)
    client = pool.acquire('127.0.0.1', 1)

    Thread.new do
      sleep(0.1)
      pool.release(client)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pool.acquire('127.0.0.1', 1)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
  end

  def test_stale_keep_alive_connection_is_not_retried_by_default
    url = serve do |c|
      respond(c, 'one') if read_request(c)
      read_request(c)
    end
    pool = MintHttp::Pool.new

    MintHttp.use_pool(pool).get("#{url}/")
    assert_raises(MintHttp::ConnectionIoError) { MintHttp.use_pool(pool).get("#{url}/") }
  end

  def test_stale_keep_alive_connection_is_retried_for_get
    connections = 0
    url = serve do |c|
      connections += 1

      if connections == 1
        respond(c, 'one') if read_request(c)
        # Server drops the idle keep-alive connection right as the next request arrives
        read_request(c)
      else
        respond(c, 'two') while read_request(c)
      end
    end
    pool = MintHttp::Pool.new(retry_stale: true)

    assert_equal 'one', MintHttp.use_pool(pool).get("#{url}/").body
    assert_equal 'two', MintHttp.use_pool(pool).get("#{url}/").body
    assert_equal 2, connections
  end

  def test_stale_keep_alive_connection_is_not_retried_for_post
    url = serve do |c|
      respond(c, 'one') if read_request(c)
      read_request(c)
    end
    pool = MintHttp::Pool.new(retry_stale: true)

    MintHttp.use_pool(pool).post("#{url}/", { a: 1 })
    assert_raises(MintHttp::ConnectionIoError) { MintHttp.use_pool(pool).post("#{url}/", { a: 2 }) }
  end

  def test_stale_keep_alive_connection_is_retried_for_post_with_idempotency_key
    connections = 0
    url = serve do |c|
      connections += 1

      if connections == 1
        respond(c, 'one') if read_request(c)
        read_request(c)
      else
        respond(c, 'two') while read_request(c)
      end
    end
    pool = MintHttp::Pool.new(retry_stale: true)

    MintHttp.use_pool(pool).post("#{url}/", { a: 1 })
    response = MintHttp.use_pool(pool).header('Idempotency-Key' => 'charge-2').post("#{url}/", { a: 2 })

    assert_equal 'two', response.body
  end

  def test_failed_retry_reports_the_first_error
    url = serve do |c|
      respond(c, 'one') if read_request(c)
      read_request(c)
      @servers.first.close # the retry cannot connect
    end
    pool = MintHttp::Pool.new(retry_stale: true)

    MintHttp.use_pool(pool).get("#{url}/")
    error = assert_raises(MintHttp::ConnectionIoError) { MintHttp.use_pool(pool).get("#{url}/") }
    assert_kind_of EOFError, error.cause
  end

  def test_no_retry_once_the_response_started
    requests = Queue.new
    url = serve do |c|
      respond(c, 'one') if read_request(c)
      requests << read_request(c)
      c.write("HTTP/1.1 201 Created\r\nContent-Length: 100\r\n\r\npartial")
    end
    pool = MintHttp::Pool.new(retry_stale: true)

    MintHttp.use_pool(pool).raise_on_truncated_body.post("#{url}/", { a: 1 })
    assert_raises(MintHttp::ProtocolError) do
      MintHttp.use_pool(pool).raise_on_truncated_body.header('Idempotency-Key' => 'charge-2').post("#{url}/", { a: 2 })
    end
    sleep(0.1)
    assert_equal 1, requests.size
  end

  def test_truncated_body_is_returned_unless_opted_in
    url = serve do |c|
      read_request(c)
      c.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly-part")
    end

    assert_equal 'only-part', MintHttp.get(url).body

    error = assert_raises(MintHttp::ProtocolError) { MintHttp.raise_on_truncated_body.get(url) }
    assert_kind_of EOFError, error.cause
  end

  def test_malformed_response_raises_net_http_error
    url = serve do |c|
      read_request(c)
      c.write("garbage\r\n\r\n")
    end

    assert_raises(Net::HTTPBadResponse) { MintHttp.get(url) }
  end

  def test_logging_non_utf8_bodies_never_fails_the_request
    url = serve do |c|
      read_request(c)
      respond(c, "\xFF\xD8\xFF\xE0binary".b, 'Content-Type' => 'application/octet-stream')
    end
    log = StringIO.new

    response = MintHttp.use_logger(Logger.new(log)).should_filter_params.filter_param('card').get(url)

    assert_equal 200, response.status_code
    assert_includes log.string, '[BINARY 10 bytes]'
  end

  # Rack::Timeout raises a RuntimeError into the request thread; MintHttp's own rescues must
  # never swallow it, or the request would keep running past its timeout.
  def test_timeout_raised_while_logging_is_not_swallowed
    url = echo_server
    fake_timeout = Class.new(RuntimeError)
    slow_logger = Logger.new(StringIO.new)
    def slow_logger.info(message = nil, &block)
      sleep(0.3)
      super
    end
    result = nil

    worker = Thread.new do
      MintHttp.use_logger(slow_logger).get("#{url}/x")
      result = :returned
    rescue fake_timeout
      result = :timed_out
    end

    sleep(0.15)
    worker.raise(fake_timeout)
    worker.join

    assert_equal :timed_out, result
  end

  def test_logging_transcodes_declared_charset
    url = serve do |c|
      read_request(c)
      respond(c, 'café'.encode('ISO-8859-1'), 'Content-Type' => 'text/plain; charset=ISO-8859-1')
    end
    log = StringIO.new

    MintHttp.use_logger(Logger.new(log)).get(url)

    assert_includes log.string, 'café'
  end

  def test_filter_param_does_not_grow_global_config
    MintHttp.filter_param('card_number', :cvc)
    size = MintHttp.config.filter_params_list.size

    3.times { MintHttp.filter_param('card_number', :cvc) }

    assert_equal size, MintHttp.config.filter_params_list.size
    assert_includes MintHttp.config.filter_params_list, :cvc
  end

  def test_logs_redact_bracketed_form_keys
    url = echo_server
    log = StringIO.new

    MintHttp.use_logger(Logger.new(log)).should_filter_params.filter_param(:cvc).as_form
            .post("#{url}/x", { 'source[cvc]' => '123', 'source[name]' => 'Ali' })

    refute_includes log.string, '123'
    assert_includes log.string, 'source%5Bname%5D=Ali'
  end

  def test_logs_redact_filtered_query_params
    url = echo_server
    log = StringIO.new

    MintHttp.use_logger(Logger.new(log)).should_filter_params.filter_param(:api_key).get("#{url}/x", api_key: 'secret', page: 2)

    refute_includes log.string, 'secret'
    assert_includes log.string, 'api_key=[FILTERED]&page=2'
  end

  # Behaviour of v1.1.3 that callers may rely on
  def test_request_building_is_unchanged
    request = MintHttp::Request.new.base_url('http://api.test/v1')

    url, = request.send(:build_request, 'get', 'charges?id=1')
    assert_equal 'http://api.test/v1/charges', url.to_s

    url, = request.send(:build_request, 'get', 'http://other.test/x')
    assert_equal 'http://api.test/v1/x', url.to_s

    url, = MintHttp::Request.new.query(page: 2).send(:build_request, 'get', 'http://api.test/x?page=1&per=10')
    assert_equal 'http://api.test/x?page=2', url.to_s

    _, net_request, = MintHttp::Request.new.content_type('application/xml').with_body('<a/>').send(:build_request, 'post', 'http://api.test/')
    assert_equal 'application/octet-stream', net_request['content-type']

    _, _, options = MintHttp::Request.new.ssl_verify_hostname(false).send(:build_request, 'get', 'https://api.test/')
    assert MintHttp::NetHttpFactory.new.defaults(options)[:verify_hostname]

    assert_equal 5000, MintHttp::Pool.new.idle_ttl
    assert_kind_of Logger, MintHttp.config.logger
    assert defined?(CGI)
  end

  def test_request_state_after_a_call_is_unchanged
    url = echo_server
    request = MintHttp::Request.new

    response = request.post("#{url}/charge", { amount: 100 })

    assert_same request, response.mint_request
    assert_equal 'post', request.method
    assert_equal "#{url}/charge", request.request_url.to_s
    assert_equal({ amount: 100 }, request.body)
  end

  # Applications instrument these methods by prepending modules (e.g. for APM), so their
  # signatures and the fact that they are called are part of the public contract.
  module Instrumented
    def self.calls = (Thread.current[:mint_http_test_calls] ||= [])

    module Request
      def send_request(method, url)
        Instrumented.calls << [:send_request, method]
        super
      end
    end

    module Pool
      def acquire(hostname, port, options = {})
        Instrumented.calls << [:acquire, hostname]
        super
      end
    end

    module NetHttp
      def start
        Instrumented.calls << [:start]
        super
      end
    end

    MintHttp::Request.prepend(Request)
    MintHttp::Pool.prepend(Pool)
    Net::HTTP.prepend(NetHttp)
  end

  def test_instrumentation_hooks_keep_working
    url = echo_server
    pool = MintHttp::Pool.new
    Instrumented.calls.clear

    MintHttp.use_pool(pool).get("#{url}/a", page: 1)
    MintHttp.use_pool(pool).post("#{url}/b", { amount: 1 })

    assert_equal [[:send_request, 'get'], [:acquire, '127.0.0.1'], [:start], [:send_request, 'post'], [:acquire, '127.0.0.1']],
                 Instrumented.calls
  end

  def test_namespace_includes_tls_settings
    factory = MintHttp::NetHttpFactory.new

    refute_equal factory.client_namespace('h', 443, ca: OpenSSL::X509::Store.new),
                 factory.client_namespace('h', 443, ca: OpenSSL::X509::Store.new)
    refute_equal factory.client_namespace('h', 443, min_version: :TLS1_2),
                 factory.client_namespace('h', 443, min_version: :TLS1_3)
  end

  def test_pool_drops_connections_inherited_through_fork
    skip 'fork not supported' unless Process.respond_to?(:fork)

    url = echo_server
    pool = MintHttp::Pool.new(idle_ttl: 60_000)
    parent_port = MintHttp.use_pool(pool).get("#{url}/parent").local_address.ip_port

    reader, writer = IO.pipe
    pid = fork do
      reader.close
      response = MintHttp.use_pool(pool).get("#{url}/child")
      writer.write("#{response.body} #{response.local_address.ip_port}")
      writer.close
      exit!(0)
    end
    writer.close
    child_body, child_port = reader.read.split(' ')
    Process.wait(pid)

    assert_equal '/child', child_body
    refute_equal parent_port.to_s, child_port
    assert_equal '/parent-again', MintHttp.use_pool(pool).get("#{url}/parent-again").body
  end
end
