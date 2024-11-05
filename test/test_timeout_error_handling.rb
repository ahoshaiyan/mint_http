# frozen_string_literal: true

require 'test_helper'

class TestTimeoutErrorHandling < Minitest::Test
  def test_read_timeout_is_raised_when_a_read_timeout_occurs
    start_read_timeout_server
    sleep(0.5)
    assert_raises(MintHttp::ReadTimeoutError) do
      MintHttp.timeout(1, 1, 1).get('http://127.0.0.1:4569')
    end
  end

  def test_open_timeout_is_raised_when_blocked_by_firewall
    assert_raises(MintHttp::OpenTimeoutError) do
      MintHttp.timeout(1, 1, 1).get('http://8.8.8.8:81')
    end
  end

  private

  def start_read_timeout_server
    Thread.new do
      server = TCPServer.new('127.0.0.1', 4569)

      client = server.accept

      client.gets
      sleep(10)
      client.write('Too late')

      client.close
      server.close
    end
  end
end
