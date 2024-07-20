# frozen_string_literal: true

module MintHttp
  class Response
    # @!attribute [r] net_request
    #   @return [Net::HTTPRequest]
    attr_reader :net_request

    # @!attribute [r] net_response
    #   @return [Net::HTTPResponse]
    attr_reader :net_response

    # @!attribute [r] mint_request
    #   @return [MintHttp::Request]
    attr_reader :mint_request

    # @!attribute [r] version
    #   @return [String]
    attr_reader :version

    # @!attribute [r] status_code
    #   @return [Integer]
    attr_reader :status_code

    # @!attribute [r] status_text
    #   @return [String]
    attr_reader :status_text

    # @!attribute [r] headers
    #   @return [Hash<String,Array[String]>]
    attr_reader :headers

    attr_accessor :time_started
    attr_accessor :time_ended
    attr_accessor :time_connected
    attr_accessor :time_total
    attr_accessor :time_connecting

    # @param [Net::HTTPResponse] net_response
    # @param [Net::HTTPRequest] net_request
    # @param [MintHttp::Request] mint_request
    def initialize(net_response, net_request, mint_request)
      @net_response = net_response
      @net_request = net_request
      @mint_request = mint_request
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
          raise AuthenticationError.new('Unauthenticated', self)
        when 403
          raise AuthorizationError.new('Forbidden', self)
        when 404
          raise NotFoundError.new('Not Found', self)
        when 400..499
          raise ClientError.new('Client Error', self)
        when 500..599
          raise ServerError.new('Server Error', self)
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

    def json?
      headers['content-type']&.include?('application/json')
    end

    def xml?
      headers['content-type']&.match?(/\/xml/)
    end

    def https?
      @net_request
    end

    def inspect
      "#<#{self.class}/#{@version} #{@status_code} #{@status_text} #{@headers.inspect}>"
    end
  end
end
