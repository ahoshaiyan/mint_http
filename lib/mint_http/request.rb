# frozen_string_literal: true

require 'base64'
require 'net/http'
require 'uri'
require 'openssl'
require 'json'

module MintHttp
  class Request
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

      header('User-Agent' => 'Mint Http')
      as_json
    end

    def use_pool(pool)
      raise ArgumentError, 'Expected a MintHttp::Pool' unless Pool === pool

      @pool = pool
      header('Connection' => 'keep-alive')
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
      accept('application/json')
    end

    def content_type(type)
      header('Content-Type' => type)
    end

    def with_body(raw)
      @body_type = :raw
      @body = raw
      content_type(nil)
      self
    end

    def as_json
      @body_type = :json
      content_type('application/json')
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
      url, net_request, options = build_request(method, url)

      res = with_client(url.hostname, url.port, options) do |http|
        http.request(net_request)
      end

      Response.new(res)
    end

    private

    def build_request(method, url)
      url = URI.parse(url)
      url = @base_url + url if @base_url

      unless %w[http https].include?(url.scheme)
        raise ArgumentError, "Only HTTP and HTTPS URLs are allowed"
      end

      url.query = URI.encode_www_form(@query)

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
      }

      [url, net_request, options]
    end

    def with_client(hostname, port, options = {})
      raise ArgumentError, 'Block is required' unless block_given?

      # Get client from pool
      net_http = @pool&.acquire(hostname, port, options)

      # make a new client if there is no pool
      unless net_http
        net_http = net_factory.make_client(hostname, port, options)
      end

      begin
        net_http.start unless net_http.started?
        yield(net_http)
      ensure
        if @pool
          @pool.release(net_http)
        else
          net_http.finish
        end
      end
    end

    def net_factory
      @net_factory ||= NetHttpFactory.new
    end
  end
end
