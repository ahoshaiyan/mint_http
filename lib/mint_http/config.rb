# frozen_string_literal: true

module MintHttp
  class Config
    # @!attribute [rw] logger
    #   @return [Logger] logger to be used for logging request details
    attr_accessor :logger

    # @!attribute [rw] logger
    #   @return [Array[String|Symbol]] logger to be used for logging request details
    attr_accessor :filter_parameters
  end
end
