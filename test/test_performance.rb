# frozen_string_literal: true

require 'test_helper'
require 'stringio'

# Work that does not change during a process or a connection is done once.
class TestPerformance < Minitest::Test
  def test_redaction_patterns_are_compiled_once_per_filter_list
    MintHttp::RequestLogger::PATTERNS.clear
    redact = ->(list) { MintHttp::RequestLogger.new(Logger.new(StringIO.new), list).send(:redact_json, '{"cvc":"123","number":"4111"}') }

    assert_equal '{"cvc":"[FILTERED]","number":"[FILTERED]"}', redact.(%w[cvc number])
    compiled = MintHttp::RequestLogger::PATTERNS[[:json, %w[cvc number]]]

    assert_equal '{"cvc":"[FILTERED]","number":"[FILTERED]"}', redact.(%w[CVC number])
    assert_same compiled, MintHttp::RequestLogger::PATTERNS[[:json, %w[cvc number]]]

    assert_equal '{"cvc":"[FILTERED]","number":"4111"}', redact.(%w[cvc])
    assert_equal 2, MintHttp::RequestLogger::PATTERNS.size
  end

  def test_connection_addresses_are_looked_up_once_per_connection
    server = TCPServer.new('127.0.0.1', 0)
    Thread.new do
      client = server.accept
      while client.gets
        while (line = client.gets) && line != "\r\n"; end
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      end
    rescue IOError, SystemCallError
      nil
    end
    pool = MintHttp::Pool.new
    url = "http://127.0.0.1:#{server.addr[1]}/"

    first = MintHttp.use_pool(pool).get(url)
    lookups = 0
    TCPSocket.prepend(Module.new { define_method(:local_address) { lookups += 1; super() } })
    second = MintHttp.use_pool(pool).get(url)

    assert_equal 0, lookups
    assert_equal first.local_address.inspect, second.local_address.inspect
    assert_equal server.addr[1], second.remote_address.ip_port
  ensure
    server&.close
  end
end
