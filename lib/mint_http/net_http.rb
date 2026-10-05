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

    # Returns true when bytes are sitting in Ruby-side buffers (Net::BufferedIO or
    # OpenSSL::Buffering) that the kernel socket no longer reports as readable.
    def pending_buffered_bytes?
      return false unless @socket

      # rbuf_size exists since net-protocol 0.2 (Ruby 3.2), older versions only have @rbuf
      buffered = if @socket.respond_to?(:rbuf_size, true)
        @socket.send(:rbuf_size)
      else
        @socket.instance_variable_get(:@rbuf).to_s.bytesize
      end
      return true if buffered > 0

      io = @socket.io
      if io.is_a?(OpenSSL::SSL::SSLSocket)
        rbuffer = io.instance_variable_get(:@rbuffer)
        return true if rbuffer && !rbuffer.empty?
        return true if io.pending > 0
      end

      false
    end
  end
end
