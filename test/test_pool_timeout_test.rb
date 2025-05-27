# frozen_string_literal: true

require 'test_helper'

class TestPoolTimeoutTest < Minitest::Test
  def start_server(port)
    alive = true

    Thread.new do
      trap('EXIT') do
        puts "Existing thread #{Thread.current.__id__}..."
        alive = false
      end

      server = TCPServer.new('127.0.0.1', port)

      while alive
        client = server.accept

        Thread.new do
          while alive
            begin
              client.gets
              client.write("HTTP/1.1 200 OK\r\nContent-Type: plain/test\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nHello There")
            rescue
              break
            end
          end

          client.close rescue nil
        end
      end

      server.close
    end

    sleep(0.5)
  end

  def test_connected_socket_should_be_the_same_for_connection_live_time
    start_server(12345)

    # Idle timeout is set higher to test TTL
    pool = MintHttp::Pool.new(ttl: 10_000, idle_ttl: 20_000)
    assert_equal(0, pool.current_size)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12345/')
    assert_equal(1, pool.current_size)

    local_address = response.local_address
    assert_instance_of(Addrinfo, local_address)

    sleep(7)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12345/')
    assert_equal(1, pool.current_size)

    assert_equal(local_address.inspect, response.local_address.inspect)
  end

  def test_connection_should_not_be_returned_after_it_times_out
    start_server(12346)

    # Idle timeout is set higher to test TTL
    pool = MintHttp::Pool.new(ttl: 10_000, idle_ttl: 20_000)
    assert_equal(0, pool.current_size)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12346/')
    assert_equal(1, pool.current_size)

    local_address = response.local_address
    assert_instance_of(Addrinfo, local_address)

    sleep(11)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12346/')
    assert_equal(1, pool.current_size)

    refute_equal(local_address.inspect, response.local_address.inspect)
  end

  def test_connected_socket_should_be_the_same_for_idle_timeout
    start_server(12347)

    # Idle timeout is set higher to test TTL
    pool = MintHttp::Pool.new(ttl: 10_000, idle_ttl: 5000)
    assert_equal(0, pool.current_size)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12347/')
    assert_equal(1, pool.current_size)

    local_address = response.local_address
    assert_instance_of(Addrinfo, local_address)

    sleep(3.5)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12347/')
    assert_equal(1, pool.current_size)

    assert_equal(local_address.inspect, response.local_address.inspect)
  end

  def test_connection_should_not_be_returned_after_its_idle_timeout_passes
    start_server(12348)

    # Idle timeout is set higher to test TTL
    pool = MintHttp::Pool.new(ttl: 10_000, idle_ttl: 5000)
    assert_equal(0, pool.current_size)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12348/')
    assert_equal(1, pool.current_size)

    local_address = response.local_address
    assert_instance_of(Addrinfo, local_address)

    sleep(6)

    response = MintHttp.use_pool(pool).get('http://127.0.0.1:12348/')
    assert_equal(1, pool.current_size)

    refute_equal(local_address.inspect, response.local_address.inspect)
  end

  def test_connection_should_not_be_returned_when_peer_closes_socket
    Thread.new do
      server = TCPServer.new('127.0.0.1', 11384)

      2.times do
        client = server.accept

        Thread.new do
          client.gets
          client.write("HTTP/1.1 200 OK\r\nContent-Type: plain/test\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nHello There\r\n")
          client.flush
          client.close
        end
      end
    end

    # Allow time for server to start
    sleep(0.5)

    pool = MintHttp::Pool.new(ttl: 30_000, idle_ttl: 30_000)
    assert_equal(0, pool.current_size)
    assert_equal(0, pool.created_connections)

    response_1 = MintHttp.use_pool(pool).get('http://127.0.0.1:11384/')

    # pool is cleaned since client closed connection
    assert_equal(0, pool.current_size)
    assert_equal(1, pool.created_connections)
    assert_equal('Hello There', response_1.body.to_s)

    # Allow sometime for other thread to close connection
    sleep(1)

    response_2 = MintHttp.use_pool(pool).get('http://127.0.0.1:11384/')
    assert_equal(0, pool.current_size)
    assert_equal(2, pool.created_connections)
    assert_equal('Hello There', response_2.body.to_s)

    refute_equal(response_1.local_address.inspect, response_2.local_address.inspect)
  end
end
