# frozen_string_literal: true

class MintHttp::NetHttpFactory
  def defaults(options = {})
    options[:open_timeout] = options[:open_timeout] || 5
    options[:write_timeout] = options[:write_timeout] || 5
    options[:read_timeout] = options[:read_timeout] || 20
    options[:ssl_timeout] = options[:ssl_timeout] || 5
    options[:keep_alive_timeout] = options[:keep_alive_timeout] || 30
    options[:verify_mode] = options[:verify_mode] || OpenSSL::SSL::VERIFY_PEER
    options[:verify_hostname] = options[:verify_hostname] || true
    options
  end

  def client_namespace(hostname, port, options = {})
    options = defaults(options)

    host_group = "#{hostname.downcase}_#{port.to_s.downcase}"
    proxy_group = "#{options[:proxy_address]}_#{options[:proxy_port]}_#{options[:proxy_user]}"
    timeout_group = "#{options[:open_timeout]}_#{options[:write_timeout]}_#{options[:read_timeout]}_#{options[:keep_alive_timeout]}"

    cert_signature = options[:cert]&.serial&.to_s
    key_signature = OpenSSL::Digest::SHA1.new(options[:key]&.to_der || '').to_s
    ssl_group = "#{options[:use_ssl]}_#{options[:ssl_timeout]}_#{options[:ca_file]}_#{cert_signature}_#{key_signature}_#{options[:verify_mode]}_#{options[:verify_hostname]}"

    "#{host_group}_#{proxy_group}_#{timeout_group}_#{ssl_group}"
  end

  # Available options:
  # proxy_address
  # proxy_port
  # proxy_user
  # proxy_pass
  # open_timeout
  # write_timeout
  # read_timeout
  # ssl_timeout
  # ca_file
  # cert
  # key
  # verify_mode
  # verify_hostname
  def make_client(hostname, port, options = {})
    options = defaults(options)

    net_http = Net::HTTP.new(hostname, port, nil)

    # Disable Net::HTTP's own retries. Its retry list includes Net::ReadTimeout,
    # so a retry would double the worst-case latency of a genuinely slow request.
    # Stale pooled connections are retried by Request#with_client instead, which
    # can tell a dead connection apart from a slow server.
    net_http.max_retries = 0

    # Set proxy options
    net_http.proxy_address = options[:proxy_address]
    net_http.proxy_port = options[:proxy_port]
    net_http.proxy_user = options[:proxy_user]
    net_http.proxy_pass = options[:proxy_pass]

    # Timeout
    net_http.open_timeout = options[:open_timeout]
    net_http.write_timeout = options[:write_timeout]
    net_http.read_timeout = options[:read_timeout]

    # SSL options
    net_http.use_ssl = options[:use_ssl]
    net_http.ssl_timeout = options[:ssl_timeout]
    net_http.cert = options[:cert]
    net_http.key = options[:key]
    net_http.verify_mode = options[:verify_mode]
    net_http.verify_hostname = options[:verify_hostname]
    net_http.min_version = options[:min_version]
    net_http.max_version = options[:max_version]

    # Keep-alive Options
    # Net::HTTP drops and reopens a connection that has sat idle longer than
    # this. It is the last guard against writing a request into a connection the
    # peer has already dropped without telling us. MintHttp::Pool derives it from
    # its own :idle_ttl so the two layers agree on when a connection is too old.
    net_http.keep_alive_timeout = options[:keep_alive_timeout]

    if OpenSSL::X509::Store === options[:ca]
      net_http.cert_store = options[:ca]
    else
      net_http.ca_file = options[:ca]
    end

    net_http
  end
end
