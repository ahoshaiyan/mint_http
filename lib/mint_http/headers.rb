# frozen_string_literal: true

class MintHttp::Headers < Hash
  def [](key)
    super(key.downcase)
  end

  def []=(key, value)
    super(key.downcase, value)
  end
end
