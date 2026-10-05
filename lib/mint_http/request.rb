# frozen_string_literal: true

require 'base64'
require 'net/http'
require 'uri'
require 'openssl'
require 'json'
require 'resolv'

module MintHttp
  class Request
    # Errors raised when a reused keep-alive connection turns out to have been closed by
    # the server while it was idle in the pool.
    STALE_CONNECTION_ERRORS = [EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EPROTOTYPE].freeze

    # Methods that are safe to send again (RFC 9110 safe methods). Other requests, such as
    # POST, may have been processed by the server and are only retried when they carry an
    # idempotency key the server uses to deduplicate them.
    RETRYABLE_METHODS = %w[GET HEAD OPTIONS].freeze
    IDEMPOTENCY_KEY_HEADERS = %w[idempotency-key x-idempotency-key].freeze

    attr_reader :base_url
    attr_reader :headers
    attr_reader :body_type
    attr_reader :body
    attr_reader :query
    attr_reader :open_timeout
    attr_reader :write_timeout
    attr_reader :read_timeout
    attr_reader :ca
    attr_reader :cert
    attr_reader :proxy_address
    attr_reader :proxy_port
    attr_reader :ssl_verify_mode
    attr_reader :ssl_verify_hostname
    attr_reader :ssl_min_version
    attr_reader :ssl_max_version

    # Attributes only available when request is made
    attr_reader :method
    attr_reader :request_url

    def initialize
      @pool = nil
      @base_url = nil
      @headers = {}
      @body_type = nil
      @body = nil
      @query = {}
      @files = []
      @open_timeout = 5
      @write_timeout = 5
      @read_timeout = 20
      @ca = nil
      @cert = nil
      @key = nil
      @proxy_address = nil
      @proxy_port = nil
      @proxy_user = nil
      @proxy_pass = nil
      @ssl_verify_mode = nil
      @ssl_verify_hostname = nil
      @ssl_min_version = nil
      @ssl_max_version = nil
      @raise_on_truncated_body = false

      @logger = MintHttp.config.logger
      @filter_params_list = MintHttp.config.filter_params_list
      @filter_params = MintHttp.config.filter_params

      header('User-Agent' => 'Mint Http')
      as_json
    end

    def use_pool(pool)
      raise ArgumentError, 'Expected a MintHttp::Pool' unless Pool === pool

      @pool = pool
      header('Connection' => 'keep-alive')

      self
    end

    def timeout(open, write, read)
      @open_timeout = open
      @write_timeout = write
      @read_timeout = read

      self
    end

    def base_url(url)
      @base_url = URI.parse(url)
      self
    end

    def ssl_verify_mode(mode)
      @ssl_verify_mode = mode
      self
    end

    def ssl_verify_hostname(verify)
      @ssl_verify_hostname = verify
      self
    end

    # Raise MintHttp::ProtocolError when the connection closes before the whole response
    # body arrived, instead of returning the truncated body.
    def raise_on_truncated_body(raise_error = true)
      @raise_on_truncated_body = raise_error
      self
    end

    def ssl_version(min, max)
      @ssl_min_version = min
      @ssl_max_version = max
      self
    end

    def use_ca(ca)
      @ca = ca
      self
    end

    def use_cert(cert, key)
      unless OpenSSL::X509::Certificate === cert
        raise ArgumentError, 'Expected an OpenSSL::X509::Certificate'
      end

      unless OpenSSL::PKey::PKey === key
        raise ArgumentError, 'Expected an OpenSSL::PKey::PKey'
      end

      @cert = cert
      @key = key

      self
    end

    def via_proxy(proxy_address, proxy_port = 3128, proxy_user = nil, proxy_pass = nil)
      @proxy_address = proxy_address
      @proxy_port = proxy_port
      @proxy_user = proxy_user
      @proxy_pass = proxy_pass

      self
    end

    def query(queries = {})
      queries.each do |k, v|
        k = k.to_s

        if v.nil?
          @query.delete(k)
          next
        end

        @query[k] = v.to_s
      end

      self
    end

    def header(headers = {})
      headers.each do |k, v|
        k = k.downcase.to_s

        if v.nil?
          @headers.delete(k)
          next
        end

        v = v.join(' ;') if Array === v
        @headers[k] = v
      end

      self
    end

    def basic_auth(username, password = '')
      header('Authorization' => 'Basic ' + Base64.strict_encode64("#{username}:#{password}"))
    end

    def token_auth(type, token)
      header('Authorization' => "#{type} #{token}")
    end

    def bearer(token)
      token_auth('Bearer', token)
    end

    def accept(type)
      header('Accept' => type)
    end

    def accept_json
      accept('application/json; charset=utf-8')
    end

    def content_type(type)
      header('Content-Type' => type)
    end

    def with_body(raw)
      @body_type = :raw
      @body = raw

      unless @headers['Content-Type']
        content_type('application/octet-stream')
      end

      self
    end

    def as_json
      @body_type = :json
      content_type('application/json; charset=utf-8')
    end

    def as_form
      @body_type = :form
      content_type('application/x-www-form-urlencoded')
    end

    def as_multipart
      @body_type = :multipart
      content_type('multipart/form-data')
    end

    def with_file(name, file, filename = nil, content_type = nil)
      unless file.respond_to?(:read)
        raise ArgumentError, "File must be an IO or IO like"
      end

      @files << [
        name,
        file,
        { filename: filename, content_type: content_type }.compact
      ]

      self
    end

    # @param [Logger] logger
    def use_logger(logger)
      @logger = logger
      self
    end

    def no_logger
      @logger = Logger.new('/dev/null')
      self
    end

    # Filtered params apply to every request: they are added to MintHttp.config.filter_params_list.
    # @param [Array[String]] params
    def filter_param(*params)
      params.each do |param|
        @filter_params_list << param unless @filter_params_list.any? { |p| p.to_s == param.to_s }
      end

      self
    end

    def should_filter_params(filter = true)
      @filter_params = filter
      self
    end

    def get(url, params = {})
      query(params).send_request('get', url)
    end

    def head(url, params = {})
      query(params).send_request('head', url)
    end

    def post(url, data = nil)
      @body = data if data
      send_request('post', url)
    end

    def put(url, data = nil)
      @body = data if data
      send_request('put', url)
    end

    def patch(url, data = nil)
      @body = data if data
      send_request('patch', url)
    end

    def delete(url, data = nil)
      @body = data if data
      send_request('delete', url)
    end

    def send_request(method, url)
      @method = method

      logger = RequestLogger.new(@logger, @filter_params_list, @filter_params)
      url, net_request, options = build_request(method, url)

      logger.log_request(self, net_request, url, method)
      logger.log_start

      begin
        response = perform_request(url, net_request, options, logger)
      rescue Exception => error
        # Also log interrupts (Timeout.timeout, Thread#raise) so aborted calls leave a trace
        logger.log_end
        logger.log_error(error)
        logger.write_log

        raise error
      end

      logger.log_end
      logger.log_response(response)
      logger.put_timing(response)
      logger.write_log

      response

    rescue SocketError => e
      if e.message.include?('getaddrinfo') || e.cause.is_a?(Resolv::ResolvError) || e.cause.is_a?(Resolv::ResolvTimeout)
        raise NameResolutionError, e.message
      else
        raise ConnectionIoError, e.message
      end

    rescue Net::OpenTimeout => e
      raise OpenTimeoutError, e.message
    rescue Net::WriteTimeout => e
      raise WriteTimeoutError, e.message
    rescue Net::ReadTimeout => e
      raise ReadTimeoutError, e.message

    rescue Errno::ECONNREFUSED => e
      raise ConnectionRefusedError, e.message
    rescue Errno::ECONNRESET => e
      raise ConnectionResetError, e.message

    rescue IOError, EOFError, Errno::EPIPE, Errno::EIO => e
      raise ConnectionIoError, e.message
    rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
      raise ConnectionError, e.message

    rescue OpenSSL::SSL::SSLError => e
      raise ConnectionSslError, e.message
    end

    private

    def perform_request(url, net_request, options, logger)
      with_client(url.hostname, url.port, options) do |http, reused|
        logger.log_connected
        logger.log_connection_info(http)
        net_response = request_with_stale_retry(http, net_request, reused, logger)

        Response.new(net_response, net_request, self, http)
      end
    end

    # With MintHttp::Pool.new(retry_stale: true), a reused keep-alive connection that the
    # server closed while idle fails before any response byte arrives: when the request is
    # safe to send again, it is sent once more on a new connection. Should that fail too,
    # the first error is raised since the request may have reached the server.
    def request_with_stale_retry(http, net_request, reused, logger)
      response_started = false

      begin
        http.request(net_request) { response_started = true }
      rescue *STALE_CONNECTION_ERRORS, OpenSSL::SSL::SSLError => error
        if response_started && @raise_on_truncated_body
          raise ProtocolError, "Incomplete response: #{error.message}"
        end

        raise unless reused && !response_started && @pool&.retry_stale && retry_stale_connection?(net_request, error)

        logger.log_retry(error)
        close_client(http)

        begin
          http.start
          logger.log_connection_info(http)
          http.request(net_request)
        rescue StandardError => retry_error
          logger.log_retry_error(retry_error)
          raise error, cause: nil
        end
      end
    end

    def retry_stale_connection?(net_request, error)
      replayable = RETRYABLE_METHODS.include?(net_request.method) ||
        IDEMPOTENCY_KEY_HEADERS.any? { |header| net_request.key?(header) }
      return false unless replayable

      # Uploaded files and body streams were consumed by the first attempt
      return false unless @files.empty? && net_request.body_stream.nil?

      # TLS connections closed without close_notify fail with "unexpected eof while reading"
      !error.is_a?(OpenSSL::SSL::SSLError) || error.message.match?(/eof/i)
    end

    def build_url(url)
      url = URI.parse(url)

      unless url.is_a?(URI::Generic)
        return url
      end

      unless @base_url
        return url
      end

      unless @base_url.path.match?(/\/$/)
        @base_url.path += '/'
      end

      @base_url + url.path.gsub(/^\/+/, '')
    end

    def build_request(method, url)
      @request_url = url = build_url(url)

      unless %w[http https].include?(url.scheme)
        raise ArgumentError, "Only HTTP and HTTPS URLs are allowed"
      end

      unless (encoded_query = URI.encode_www_form(@query)).empty?
        url.query = encoded_query
      end

      net_request = case method.to_s
        when 'get'
          @body_type = nil
          Net::HTTP::Get.new(url)
        when 'head'
          @body_type = nil
          Net::HTTP::Head.new(url)
        when 'post'
          Net::HTTP::Post.new(url)
        when 'put'
          Net::HTTP::Put.new(url)
        when 'patch'
          Net::HTTP::Patch.new(url)
        when 'delete'
          Net::HTTP::Delete.new(url)
        else
          raise ArgumentError, "Unsupported HTTP method #{method}"
      end

      # add body
      case @body_type
        when nil
          # Ignore body
        when :raw
          net_request.body = @body
        when :json
          net_request.body = @body.to_json if @body

          if String === @body
            net_request.body = @body
          end
        when :form
          net_request.body = URI.encode_www_form(@body) if @body
        when :multipart
          params = []
          params.concat(@body.map { |k, v| [k.to_s, v.to_s] }) if Hash === @body
          params.concat(@files)
          net_request.set_form(params, 'multipart/form-data')
        else
          raise ArgumentError, "Invalid body type #{@body_type}"
      end

      # add headers
      @headers.each do |k, v|
        net_request.send(:set_field, k, v)
      end

      options = {
        use_ssl: url.scheme == 'https',
        open_timeout: @open_timeout,
        write_timeout: @write_timeout,
        read_timeout: @read_timeout,
        ca: @ca,
        cert: @cert,
        key: @key,
        proxy_address: @proxy_address,
        proxy_port: @proxy_port,
        proxy_user: @proxy_user,
        proxy_pass: @proxy_pass,
        verify_mode: @ssl_verify_mode,
        verify_hostname: @ssl_verify_hostname,
        min_version: @ssl_min_version,
        max_version: @ssl_max_version,
        raise_on_truncated_body: @raise_on_truncated_body,
      }

      [url, net_request, options]
    end

    # Yields a started client and whether it is a reused keep-alive connection.
    def with_client(hostname, port, options = {})
      raise ArgumentError, 'Block is required' unless block_given?

      net_http = nil
      completed = false

      begin
        # Get client from pool, make a new client if there is no pool
        net_http = @pool ? @pool.checkout(hostname, port, options) : net_factory.make_client(hostname, port, options)

        reused = net_http.started?
        net_http.start unless reused

        result = yield(net_http, reused)
        completed = true
        result
      ensure
        # Interrupts (Timeout.timeout, Thread#raise) are deferred while the connection is
        # returned so its pool slot cannot leak. Should one land before this point, the pool
        # reclaims the slot (see MintHttp::PoolEntry#leaked?).
        Thread.handle_interrupt(Object => :never) do
          if net_http
            # A request that did not complete leaves the connection in an unknown state
            # (e.g. its response still unread), so it must never be handed out again.
            close_client(net_http) if !@pool || !completed
            @pool&.release(net_http)
          end
        end
      end
    end

    def close_client(net_http)
      net_http.finish if net_http.started?
    rescue StandardError
      nil
    end

    def net_factory
      @net_factory ||= NetHttpFactory.new
    end

    def clock_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
