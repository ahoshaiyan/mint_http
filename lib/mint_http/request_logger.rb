# frozen_string_literal: true

require 'cgi'

module MintHttp
  class RequestLogger
    MAX_BODY_SIZE = 15 * 1024
    BODY_ALLOWED_TYPES = [/application\/.+/, /text\/.+/]

    attr_reader :logger
    attr_reader :filter_list
    attr_reader :time_started
    attr_reader :time_ended
    attr_reader :time_connected
    attr_reader :time_total
    attr_reader :time_connecting
    attr_reader :tls_config

    # @param [Logger] logger
    # @param [Array[String|Symbol]] request
    def initialize(logger, filter_list, filter = true)
      @logger = logger
      @filter_list = filter_list.map(&:downcase)
      @filter = filter
      @time_started = 0.0
      @time_ended = 0.0
      @time_connected = 0.0
      @time_total = 0.0
      @time_connecting = 0.0

      @request = nil
      @net_request = nil
      @response = nil
      @error = nil
    end

    def log_request(request, net_request)
      @request = request
      @net_request = net_request
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

    def write_log
      path = build_path(@request.request_url)
      version = @response&.version || '1.1'

      tls = 'None'
      if @tls_config
        tls = "#{@tls_config[:version]} Cipher: #{@tls_config[:cipher]}"
      end

      buffer = String.new
      buffer << <<~TXT
        MintHttp Log (#{@request.request_url})
        @@ Timeouts: #{@request.open_timeout}, #{@request.write_timeout}, #{@request.read_timeout}
        @@ Time: #{@time_started.round(3)} -> #{@time_connected.round(3)} connecting: #{time_connecting.round(3)} total: #{@time_total.round(3)} seconds
        @@ TLS: #{tls}
        -> #{@request.method.upcase} #{path} HTTP/#{version}
        #{masked_headers(@net_request.each_header.to_h, '-> ')}
        -> #{masked_body(@net_request.body, @request.headers['content-type'])}
        =======
      TXT

      if @response
        buffer << <<~TXT
          <- Response: HTTP/#{@response.version} #{@response.status_code} #{@response.status_text}
          #{masked_headers(@response.headers, '<- ')}
          <- Length: #{@response.body.bytesize} Body: #{masked_body(@response.body, @response.headers['content-type'])}
        TXT
      end

      if @error
        buffer << "!! Error: #{@error.class}, message: #{@error.message}"
      end

      unless buffer.valid_encoding?
        raise 'Buffer has not valid encoding'
      end

      @logger.info(buffer.strip)
    end

    def log_connection_info(http)
      @tls_config = http.instance_eval do
        if use_ssl?
          { version: @socket.io.ssl_version, cipher: @socket.io.cipher[0] }
        else
          nil
        end
      end
    end

    private

    def clock_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def build_path(url)
      full_path = url.path.dup

      if url.query
        full_path << "?#{url.query}"
      end

      if url.fragment
        full_path << "##{url.fragment}"
      end

      full_path
    end

    def lower_case_filter_list
      @_lower_case_filter_list ||= @filter_list.map(&:downcase)
    end

    def filter_query(query)
      unless @filter
        return query
      end

      filtered = CGI::parse(query || '')
        .to_h { |k, v| [k, lower_case_filter_list.include?(v) ? '[FILTERED]' : v] }

      URI.encode_www_form(filtered)
    end

    def masked_headers(headers, prefix = '')
      headers
        .map { |k, v| [k.split('-').map(&:capitalize).join('-'), v] }
        .map { |k, v| "#{prefix}#{k}: #{@filter && lower_case_filter_list.include?(k.downcase) ? '[FILTERED]' : v}" }
        .join("\n")
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

      unless @filter
        return body
      end

      if type.match?(/json/)
        redact_json(body)
      elsif type.match?(/xml/)
        redact_xml(body)
      else
        body
      end
    end

    def body_allowed?(content_type)
      BODY_ALLOWED_TYPES.any? { |pattern| pattern.match?(content_type) }
    end

    def redact_json(json)
      @json_patterns ||= @filter_list.map do |keyword|
        keyword = Regexp.escape(keyword)
        Regexp.compile("\"(#{keyword})\"(\\s*):(\\s*)(?>\".+?(?<!\\\\)\"|\\d+(?>\\.\\d+)?)", Regexp::IGNORECASE | Regexp::EXTENDED)
      end

      @json_patterns.inject(json) do |carry, pattern|
        carry.gsub(pattern, '"\1"\2:\3"[FILTERED]"')
      end
    end

    def redact_xml(raw)
      @xml_patterns ||= @filter_list.map do |keyword|
        keyword = Regexp.escape(keyword)
        Regexp.compile("<#{keyword}(?>.|\\n)+?</(#{keyword})>", Regexp::IGNORECASE | Regexp::EXTENDED)
      end

      @xml_patterns.inject(raw) do |carry, pattern|
        carry.gsub(pattern, '<\1>[FILTERED]</\1>')
      end
    end
  end
end
