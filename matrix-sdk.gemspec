# frozen_string_literal: true

require File.join File.expand_path('lib', __dir__), 'matrix_sdk/version'

Gem::Specification.new do |spec|
  spec.name          = 'matrix_sdk'
  spec.version       = MatrixSdk::VERSION
  spec.authors       = ['Alexander Olofsson']
  spec.email         = ['ace@haxalot.com']

  spec.summary       = 'SDK for applications using the Matrix protocol'
  spec.description   = spec.summary
  spec.homepage      = 'https://github.com/ananace/ruby-matrix-sdk'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'logging', '~> 2'

  spec.add_development_dependency 'mocha'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'simplecov'
  spec.add_development_dependency 'test-unit'

  # TODO: Put this in a better location
  spec.add_development_dependency 'ci_reporter_test_unit'
end
