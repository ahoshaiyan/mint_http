# frozen_string_literal: true

require 'logger'

require_relative 'mint_http/version'
require_relative 'mint_http/config'
require_relative 'mint_http/pool_entry'
require_relative 'mint_http/pool'
require_relative 'mint_http/headers'
require_relative 'mint_http/errors'
require_relative 'mint_http/net_http_factory'
require_relative 'mint_http/request_logger'
require_relative 'mint_http/response'
require_relative 'mint_http/request'

module MintHttp
  class << self
    def init_mint
      config.logger = Logger.new('/dev/null')
      config.filter_params_list = []
      config.filter_params = false
    end

    # @return [MintHttp::Config]
    # noinspection RbsMissingTypeSignature,RubyClassVariableUsageInspection
    def config
      @@config ||= MintHttp::Config.new
    end

    # @return [::MintHttp::Request]
    def method_missing(method, *args)
      request = Request.new
      request.send(method, *args)
    end
  end
end

MintHttp.init_mint
