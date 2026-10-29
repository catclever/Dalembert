# frozen_string_literal: true

require_relative "lib/dalembert/version" if File.exist?("lib/dalembert/version.rb")

Gem::Specification.new do |spec|
  spec.name          = "dalembert"
  spec.version       = defined?(Dalembert::VERSION) ? Dalembert::VERSION : "0.1.0"
  spec.authors       = ["AI"]
  spec.email         = ["ai@example.com"]

  spec.summary       = "The Encyclopedic Coding Intelligence & Documentation Reading Agent"
  spec.description   = "Dalembert is the cloud knowledge, doc-reading, and open-source intelligence brain for the Descartes ecosystem."
  spec.homepage      = "https://github.com/catclever/Dalembert"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/catclever/Dalembert"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.bindir        = "bin"
  spec.executables   = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "descartes"
  spec.add_dependency "descartes-produit"
  spec.add_dependency "ruby_llm"
end
