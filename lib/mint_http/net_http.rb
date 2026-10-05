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

    # Local and remote address of the current connection. They cannot change for the life
    # of a connection, so they are looked up once per connection instead of per request.
    def connection_addresses
      socket = underlying_tcp_socket

      unless @mint_addresses_socket.equal?(socket)
        @mint_addresses = [(socket.local_address rescue nil), (socket.remote_address rescue nil)]
        @mint_address_labels = nil
        @mint_addresses_socket = socket
      end

      @mint_addresses
    end

    # The connection addresses as "ip:port" (or 'N/A'), formatted once per connection
    def connection_address_labels
      addresses = connection_addresses
      @mint_address_labels ||= addresses.map { |a| a ? "#{a.ip_address}:#{a.ip_port}" : 'N/A' }
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
