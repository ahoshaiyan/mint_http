# frozen_string_literal: true

require 'cgi'

module MintHttp
  class RequestLogger
    MAX_BODY_SIZE = 15 * 1024
    BODY_ALLOWED_TYPES = [/application\/.+/, /text\/.+/]

    # Redaction regexes compiled once per filter list, compiling them on every request was
    # most of the cost of logging
    PATTERNS = {}
    PATTERNS_LOCK = Mutex.new

    def self.patterns(kind, keywords, &compile)
      PATTERNS[[kind, keywords]] || PATTERNS_LOCK.synchronize do
        PATTERNS.clear if PATTERNS.size > 64
        PATTERNS[[kind, keywords.dup.freeze]] ||= keywords.map { |keyword| compile.call(Regexp.escape(keyword)) }.freeze
      end
    end

    attr_reader :logger
    attr_reader :time_started
    attr_reader :time_ended
    attr_reader :time_connected
    attr_reader :time_total
    attr_reader :time_connecting
    attr_reader :tls_config
    attr_reader :local_address
    attr_reader :remote_address

    # @param [Logger] logger
    # @param [Array[String|Symbol]] request
    def initialize(logger, filter_list, filter = true)
      @logger = logger
      @raw_filter_list = filter_list
      @filter = filter
      @time_started = 0.0
      @time_ended = 0.0
      @time_connected = 0.0
      @time_total = 0.0
      @time_connecting = 0.0

      @request = nil
      @net_request = nil
      @url = nil
      @method = nil
      @response = nil
      @error = nil
      @retried_after = nil
      @retry_error = nil
    end

    # The URL and method are kept here since a Request object may be shared between threads.
    def log_request(request, net_request, url = request.request_url, method = request.method)
      @request = request
      @net_request = net_request
      @url = url
      @method = method
    end

    # A request was sent once more after a stale keep-alive connection failed with error
    def log_retry(error)
      @retried_after = error
    end

    def log_retry_error(error)
      @retry_error = error
    end

    def log_response(response)
      @response = response
    end

    def log_error(error)
      @error = error
    end

    def log_start
      @time_started = clock_time
    end

    def log_end
      @time_ended = clock_time
      @time_total = @time_ended - @time_started
    end

    def log_connected
      @time_connected = clock_time
      @time_connecting = @time_connected - @time_started
    end

    # @param [MintHttp::Response] response
    def put_timing(response)
      response.time_started = @time_started
      response.time_ended = @time_ended
      response.time_connected = @time_connected
      response.time_total = @time_total
      response.time_connecting = @time_connecting
    end

    # Logging must never fail a request: any error here is reported as a warning only.
    # Interrupts (e.g. Rack::Timeout) are deferred until the log is written so that rescue
    # cannot swallow them.
    def write_log
      Thread.handle_interrupt(Object => :never) { build_and_write_log }
    end

    def log_connection_info(http)
      return if discarding_logger?

      Thread.handle_interrupt(Object => :never) { read_connection_info(http) }
    end

    # Lower-cased params to filter, built only when a log is written
    def filter_list
      @filter_list ||= @raw_filter_list.map { |param| param.to_s.downcase }.uniq
    end

    private

    def build_and_write_log
      return if discarding_logger?

      path = build_path(@url)
      version = @response&.version || '1.1'

      tls = 'None'
      if @tls_config
        tls = "#{@tls_config[:version]} Cipher: #{@tls_config[:cipher]}"
      end

      local_address, remote_address = @address_labels || ['N/A', 'N/A']

      buffer = String.new(encoding: 'UTF-8')
      buffer << <<~TXT
        MintHttp Log (#{loggable_url(@url)})
        @@ Timeouts: #{@request.open_timeout}, #{@request.write_timeout}, #{@request.read_timeout}
        @@ Time: #{@time_started.round(3)} -> #{@time_connected.round(3)} connecting: #{time_connecting.round(3)} total: #{@time_total.round(3)} seconds
        @@ TLS: #{tls}
        @@ Address: #{local_address} -> #{remote_address}
        -> #{@method.upcase} #{path} HTTP/#{version}
        #{masked_headers(@net_request.each_header.to_h, '-> ')}
        -> #{masked_body(@net_request.body, @request.headers['content-type'])}
        =======
      TXT

      if @response
        buffer << <<~TXT
          <- Response: HTTP/#{@response.version} #{@response.status_code} #{utf8(@response.status_text)}
          #{masked_headers(@response.headers, '<- ')}
          <- Length: #{@response.body&.bytesize || 0} Body: #{masked_body(@response.body, @response.headers['content-type'])}
        TXT
      end

      if @retried_after
        buffer << "!! Retried on a new connection after: #{@retried_after.class}, message: #{utf8(@retried_after.message)}\n"
      end

      if @retry_error
        buffer << "!! Retry failed: #{@retry_error.class}, message: #{utf8(@retry_error.message)}\n"
      end

      if @error
        buffer << "!! Error: #{@error.class}, message: #{utf8(@error.message)}"
      end

      @logger.info(buffer.scrub('?').strip)
    rescue StandardError => e
      @logger.warn("MintHttp failed to write request log: #{e.class}: #{e.message}") rescue nil
    end

    def read_connection_info(http)
      @tls_config = http.instance_eval do
        if use_ssl?
          { version: @socket.io.ssl_version, cipher: @socket.io.cipher[0] }
        else
          nil
        end
      end

      if http.underlying_tcp_socket.is_a?(TCPSocket)
        @local_address, @remote_address = http.connection_addresses
        @address_labels = http.connection_address_labels
      end
    rescue StandardError
      # e.g. Errno::ENOTCONN when the peer already reset the connection
      nil
    end

    # Nothing would be written: no logger, a level above INFO, or a plain Logger writing
    # nowhere such as the default Logger.new('/dev/null')
    def discarding_logger?
      return true if @logger.nil?
      return true if @logger.respond_to?(:info?) && !@logger.info?
      return false unless @logger.instance_of?(::Logger)

      logdev = @logger.instance_variable_get(:@logdev)
      logdev.nil? || (logdev.respond_to?(:filename) && logdev.filename == File::NULL)
    end

    def clock_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def loggable_url(url)
      return url.to_s unless url.query

      "#{url.to_s.split('?', 2).first}?#{filter_query(url.query)}"
    end

    def build_path(url)
      full_path = url.path.dup

      if url.query
        full_path << "?#{filter_query(url.query)}"
      end

      if url.fragment
        full_path << "##{url.fragment}"
      end

      full_path
    end

    def lower_case_filter_list
      filter_list
    end

    def filter_query(query)
      unless @filter
        return query
      end

      URI.decode_www_form(query.to_s).map do |k, v|
        value = filtered_key?(k) ? '[FILTERED]' : URI.encode_www_form_component(v)
        "#{URI.encode_www_form_component(k)}=#{value}"
      end.join('&')
    rescue ArgumentError
      '[FILTERED]'
    end

    def masked_headers(headers, prefix = '')
      headers
        .map { |k, v| [k.split('-').map(&:capitalize).join('-'), v] }
        .map { |k, v| "#{prefix}#{k}: #{@filter && lower_case_filter_list.include?(k.downcase) ? '[FILTERED]' : utf8(v)}" }
        .join("\n")
    end

    # Matches plain keys and each part of bracketed keys such as source[number]
    def filtered_key?(key)
      key.downcase.scan(/[^\[\]]+/).any? { |part| lower_case_filter_list.include?(part) }
    end

    def utf8(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?')
    end

    def masked_body(body, type)
      type ||= 'application/octet-stream'

      size = body&.bytesize || 0
      if size == 0
        return '[EMPTY]'
      end

      if size > MAX_BODY_SIZE
        return '[LARGE]'
      end

      unless body_allowed?(type)
        return '[COMPLEX]'
      end

      unless (body = loggable_text(body, type))
        return "[BINARY #{size} bytes]"
      end

      unless @filter
        return body
      end

      if type.match?(/json/)
        redact_json(body)
      elsif type.match?(/xml/)
        redact_xml(body)
      elsif type.match?(/x-www-form-urlencoded/)
        filter_query(body)
      else
        body
      end
    end

    # Returns the body as valid UTF-8 (transcoded from its declared charset), or nil when
    # it is not text.
    def loggable_text(body, type)
      charset = type[/charset\s*=\s*"?([^";\s]+)/i, 1]
      encoding = Encoding.find(charset) rescue nil if charset

      [encoding, Encoding::UTF_8].compact.uniq.each do |candidate|
        next if candidate == Encoding::BINARY

        text = body.dup.force_encoding(candidate)
        next unless text.valid_encoding?

        return candidate == Encoding::UTF_8 ? text : text.encode(Encoding::UTF_8)
      rescue EncodingError
        next
      end

      nil
    end

    def body_allowed?(content_type)
      BODY_ALLOWED_TYPES.any? { |pattern| pattern.match?(content_type) }
    end

    def redact_json(json)
      patterns = self.class.patterns(:json, filter_list) do |keyword|
        Regexp.compile("\"(#{keyword})\"(\\s*):(\\s*)(?>\".+?(?<!\\\\)\"|\\d+(?>\\.\\d+)?)", Regexp::IGNORECASE | Regexp::EXTENDED)
      end

      patterns.inject(json) do |carry, pattern|
        carry.gsub(pattern, '"\1"\2:\3"[FILTERED]"')
      end
    end

    def redact_xml(raw)
      patterns = self.class.patterns(:xml, filter_list) do |keyword|
        Regexp.compile("<#{keyword}(?>.|\\n)+?</(#{keyword})>", Regexp::IGNORECASE | Regexp::EXTENDED)
      end

      patterns.inject(raw) do |carry, pattern|
        carry.gsub(pattern, '<\1>[FILTERED]</\1>')
      end
    end
  end
end
