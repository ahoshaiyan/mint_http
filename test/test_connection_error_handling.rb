# frozen_string_literal: true

require 'test_helper'

class TestConnectionErrorHandling < Minitest::Test
  def test_connection_refused_raised_when_no_listening_server_exists
    assert_raises(MintHttp::ConnectionRefusedError) do
      MintHttp.timeout(1, 1, 1).get('http://127.0.0.1:9998')
    end
  end

  def test_open_timeout_is_raised_when_blocked_by_firewall
    start_connection_reset_server
    sleep(0.5)
    assert_raises(MintHttp::ConnectionResetError) do
      MintHttp.timeout(1, 1, 1).get('http://127.0.0.1:4568')
    end
  end

  def test_name_resolution_error_raised_when_resolving_unknown_name
    error = assert_raises(MintHttp::NameResolutionError) do
      MintHttp.timeout(1, 1, 1).get('http://no.example.com')
    end

    assert_equal Socket::ResolutionError, error.cause.class

    # Test error is raised when using resolv-replace
    require 'resolv-replace'
    error = assert_raises(MintHttp::NameResolutionError) do
      MintHttp.timeout(1, 1, 1).get('http://no.example.com')
    end

    assert_equal Resolv::ResolvError, error.cause.cause.class
  end

  def test_connection_ssl_error_is_raised_when_ssl_error_happens
    start_bad_ssl_server
    sleep(0.5)
    assert_raises(MintHttp::ConnectionSslError) do
      MintHttp.timeout(1, 1, 1).get('https://127.0.0.1:4567')
    end
  end

  private

  def start_connection_reset_server
    Thread.new do
      server = TCPServer.new('127.0.0.1', 4568)

      client = server.accept

      client.close
      server.close
    end
  end

  def start_bad_ssl_server
    Thread.new do
      server = TCPServer.new('127.0.0.1', 4567)

      client = server.accept
      client.gets
      client.write("HTTP/1.1 201 OK\r\n\r\n")

      client.close
      server.close
    end
  end
end
