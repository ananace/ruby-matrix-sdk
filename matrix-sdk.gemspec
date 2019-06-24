# frozen_string_literal: true

require File.join File.expand_path('lib', __dir__), 'matrix_sdk/version'

Gem::Specification.new do |spec|
  spec.name             = 'matrix_sdk'
  spec.version          = MatrixSdk::VERSION
  spec.authors          = ['Alexander Olofsson']
  spec.email            = ['ace@haxalot.com']

  spec.summary          = 'SDK for applications using the Matrix protocol'
  spec.description      = spec.summary
  spec.homepage         = 'https://github.com/ananace/ruby-matrix-sdk'
  spec.license          = 'MIT'

  spec.extra_rdoc_files = %w[CHANGELOG.md LICENSE.txt README.md]
  spec.files            = Dir['lib/**/*'] + spec.extra_rdoc_files

  spec.add_development_dependency 'mocha'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'simplecov'
  spec.add_development_dependency 'test-unit'

  # TODO: Put this in a better location
  spec.add_development_dependency 'ci_reporter_test_unit'

  spec.add_dependency 'logging', '~> 2'
end
