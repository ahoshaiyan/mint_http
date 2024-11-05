# frozen_string_literal: true

module MintHttp
  class Error < StandardError; end

  # Errno::EHOSTUNREACH: The network host is unreachable, often due to network configuration issues or connectivity problems.
  # ENETUNREACH
  class ConnectionError < Error; end

  # Errno::ECONNREFUSED: The connection was refused by the remote server, often because the port is closed or the server is not running.
  class ConnectionRefusedError < ConnectionError; end

  # Errno::ECONNRESET: The connection was reset by the peer (the other end of the connection), typically due to abrupt disconnection.
  class ConnectionResetError < ConnectionError; end

  # Errno::ECONNABORTED: The connection was aborted, often due to the network or the other side abruptly closing the connection.
  class ConnectionAbortedError < ConnectionError; end

  # IOError
  # EOFError: Raised when an end-of-file condition is reached, often indicating that the connection was closed by the peer during reading.
  # Errno::EPIPE: Writing to a closed socket results in this error, indicating a "broken pipe."
  # Errno::EIO: Input/output error, typically indicating an issue with reading or writing to the socket due to a system-level error.
  class ConnectionIoError < ConnectionError; end

  # DNS Errors
  # SocketError: getaddrinfo
  # Resolv::ResolvError
  # Resolv::ResolvTimeout
  class NameResolutionError < ConnectionError; end

  # SSL Error
  # OpenSSL::SSL::SSLError
  class ConnectionSslError < ConnectionError; end

  class TimeoutError < Error; end
  class ReadTimeoutError < TimeoutError; end
  class WriteTimeoutError < TimeoutError; end
  class OpenTimeoutError < TimeoutError; end

  class ResponseError < Error
    # @return [HTTP::Response]
    attr_reader :response

    def initialize(msg, response)
      super(msg)
      @response = response
    end

    def to_s
      response.inspect
    end
  end

  class ServerError < ResponseError; end
  class BadGatewayError < ServerError; end
  class ServiceUnavailableError < ServerError; end
  class GatewayTimeoutError < ServerError; end


  class ClientError < ResponseError; end
  class NotFoundError < ClientError; end
  class AuthenticationError < ClientError; end
  class AuthorizationError < ClientError; end
end
