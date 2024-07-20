# frozen_string_literal: true

module MintHttp
  class Config
    # @!attribute [rw] logger
    #   @return [Logger] logger to be used for logging request details
    attr_accessor :logger

    # @!attribute [rw] filter_params_list
    #   @return [Array[String|Symbol]] logger to be used for logging request details
    attr_accessor :filter_params_list

    # @!attribute [rw] filter_params
    #   @return [Boolean] indicate if MintHttp should filter out params from request logs
    attr_accessor :filter_params
  end
end
