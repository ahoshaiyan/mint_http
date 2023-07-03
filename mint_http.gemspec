# frozen_string_literal: true

require_relative "lib/mint_http/version"

Gem::Specification.new do |spec|
  spec.name = "mint_http"
  spec.version = MintHttp::VERSION
  spec.authors = ["Ali Alhoshaiyan"]
  spec.email = ["ahoshaiyan@fastmail.com"]

  spec.summary = "A small fluent HTTP client."
  spec.description = "Like a mint breeze, MintHttp allows you to write simple HTTP requests while giving you the full power of Net::HTTP."
  spec.homepage = "https://github.com/ahoshaiyan/mint_http"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.6"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) || f.start_with?(*%w[bin/ test/ spec/ features/ .git .circleci appveyor])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "net-http"
  spec.add_dependency "openssl"
  spec.add_dependency "json"
  spec.add_dependency "uri"
  spec.add_dependency "base64"
end
