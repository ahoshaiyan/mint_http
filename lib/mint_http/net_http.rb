# frozen_string_literal: true

module Net
  class HTTP
    def buffered_socket
      @socket
    end

    def underlying_tcp_socket
      socket = @socket&.io

      if socket.is_a?(OpenSSL::SSL::SSLSocket)
        socket = socket.io
      end

      socket
    end
  end
end
