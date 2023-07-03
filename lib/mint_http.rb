# frozen_string_literal: true

require_relative 'mint_http/version'
require_relative 'mint_http/pool_entry'
require_relative 'mint_http/pool'
require_relative 'mint_http/headers'
require_relative 'mint_http/errors/response_error'
require_relative 'mint_http/errors/server_error'
require_relative 'mint_http/errors/client_error'
require_relative 'mint_http/errors/authorization_error'
require_relative 'mint_http/errors/authentication_error'
require_relative 'mint_http/errors/not_found_error'
require_relative 'mint_http/net_http_factory'
require_relative 'mint_http/response'
require_relative 'mint_http/request'

module MintHttp
  class << self
    # @return [::MintHttp::Request]
    def method_missing(method, *args)
      request = Request.new
      request.send(method, *args)
    end
  end
end
