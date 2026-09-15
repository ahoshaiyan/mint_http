# frozen_string_literal: true

require 'test_helper'

# Faults that used to escape send_request as raw Ruby exceptions, so that
# rescue MintHttp::Error never caught them.
class TestErrorMapping < Minitest::Test
  MAPPINGS = {
    Errno::ECONNABORTED => MintHttp::ConnectionAbortedError,
    Errno::ENETRESET => MintHttp::ConnectionResetError,
    Errno::ETIMEDOUT => MintHttp::ConnectionError,
    Errno::EHOSTDOWN => MintHttp::ConnectionError,
    Errno::ENETDOWN => MintHttp::ConnectionError,
    Errno::EADDRNOTAVAIL => MintHttp::ConnectionError,
    Net::HTTPBadResponse => MintHttp::ConnectionIoError,
  }.freeze

  def test_network_faults_are_mapped_to_mint_http_errors
    MAPPINGS.each do |raw, expected|
      error = assert_raises(expected) do
        request_raising(raw.new('simulated')).send_request('get', 'http://example.com/')
      end

      assert_kind_of(MintHttp::Error, error, "#{raw} must be catchable as MintHttp::Error")
    end
  end

  def test_connection_aborted_error_is_reachable
    # The class was declared in errors.rb but nothing ever raised it.
    assert_raises(MintHttp::ConnectionAbortedError) do
      request_raising(Errno::ECONNABORTED.new('aborted')).send_request('get', 'http://example.com/')
    end
  end

  def test_pool_timeout_error_is_not_a_connection_error
    # A saturated pool is not a network fault and must not be retried as one.
    assert_operator(MintHttp::PoolTimeoutError, :<, MintHttp::Error)
    refute_operator(MintHttp::PoolTimeoutError, :<, MintHttp::ConnectionError)
  end

  private

  def request_raising(error)
    request = MintHttp::Request.new.no_logger
    request.define_singleton_method(:with_client) { |*_args, &_block| raise error }
    request
  end
end
