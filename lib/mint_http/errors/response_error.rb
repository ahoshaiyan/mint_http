# frozen_string_literal: true

class MintHttp::ResponseError < StandardError
  # @return [HTTP::Response]
  attr_reader :response

  def initialize(msg, response)
    super(msg)
    @response = response
  end

  def to_s
    response.inspect
  end
end
