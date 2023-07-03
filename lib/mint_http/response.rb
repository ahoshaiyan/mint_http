# frozen_string_literal: true

module MintHttp
  class Response
    attr_reader :net_response
    attr_reader :version
    attr_reader :status_code
    attr_reader :status_text
    attr_reader :headers

    def initialize(net_response)
      @net_response = net_response
      @version = net_response.http_version
      @status_code = net_response.code.to_i
      @status_text = net_response.message
      @headers = Headers.new.merge(net_response.each_header.to_h)
    end

    def success?
      (200..299).include?(@status_code)
    end

    def redirect?
      (300..399).include?(@status_code)
    end

    def client_error?
      (400..499).include?(@status_code)
    end

    def unauthenticated?
      @status_code == 401
    end

    def unauthorized?
      @status_code == 403
    end

    def not_found?
      @status_code == 404
    end

    def server_error?
      (500..599).include?(@status_code)
    end

    def raise!
      case @status_code
        when 401
          raise Errors::AuthenticationError.new('Unauthenticated', self)
        when 403
          raise Errors::AuthorizationError.new('Forbidden', self)
        when 404
          raise Errors::NotFoundError.new('Not Found', self)
        when 400..499
          raise Errors::ClientError.new('Client Error', self)
        when 500..599
          raise Errors::ClientError.new('Server Error', self)
        else
          self
      end
    end

    def body
      net_response.body
    end

    def json
      @json ||= JSON.parse(body)
    end

    def inspect
      "#<#{self.class}/#{@version} #{@status_code} #{@status_text} #{@headers.inspect}>"
    end
  end
end
