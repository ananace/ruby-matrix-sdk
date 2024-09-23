require 'test_helper'

class ApiCSVerificationTest < Test::Unit::TestCase
  def setup
    reset_matrix_api

    begin
      @fixture = Psych.load_file('test/fixtures/cs_api_methods.yaml', aliases: true)
    rescue ArgumentError
      @fixture = Psych.load_file('test/fixtures/cs_api_methods.yaml')
    end

    Hash.class_eval do
      def deep_symbolize_keys
        JSON.parse(JSON[self], symbolize_names: true)
      end
    end
    Array.class_eval do
      def deep_symbolize_keys
        JSON.parse(JSON[self], symbolize_names: true)
      end
    end
  end

  def test_fixtures
    @fixture.each do |function, data|
      unless data.key? 'method'
        puts "Skipping test of #{function} due to missing method"
        next
      end
      unless @api.respond_to? data['method']
        puts "Skipping test of #{function} due to unimplemented method #{data['method']}"
        next
      end

      verb, uri = function.split('|')
      verb = verb.downcase.to_sym
      uri = File.join 'https://example.com', uri

      modifiers = []
      (data['requests'] || []).each do |request|
        reset_matrix_api
        modifiers << {
          query: request['query'] ? URI.encode_www_form(request['query']) : nil,
          body: request['body']
        }.compact if request['query'] || request['body']

        response = request.fetch('response', {})
        @api.expects(:request).with do |method, _api, path, options|
          options ||= {}
          assert_equal request['method'], method if request.key?('method')
          assert_equal request['path'], path if request.key?('path')
          assert_equal request['query']&.deep_symbolize_keys, options[:query]&.deep_symbolize_keys if request.key?('query')
          if request.key?('body')
            if request['body'].is_a? String
              assert_equal request['body'], options[:body]
            else
              assert_equal request['body']&.deep_symbolize_keys, options[:body]&.deep_symbolize_keys
            end
          end

          if request.key? 'headers'
            request['headers'].each do |header, expected|
              assert_equal expected, options[:headers][header]
            end
          end

          true
        end.returns(response)

        assert(call_api(data['method'], request['args'].deep_symbolize_keys))
      end

      next unless data.key? 'results'

      data['results'].each do |code, body|
        WebMock.reset!
        reset_matrix_api

        if data.key? 'requests'
          req = data['requests'].first
          args = req['args'].deep_symbolize_keys if req['args']
          uri = File.join 'https://example.com/_matrix/client/v3', req['path'] if req['path']
        else
          args = []
        end

        modifiers.each do |mod|
          stub_request(verb, uri).with(**mod).to_return_json(status: code, body: body)
        end
        stub_request(verb, uri).to_return_json(status: code, body: body) if modifiers.empty?

        if code.to_s[0] == '2'
          assert(!call_api(data['method'], args).nil?)
        else
          assert_raises(MatrixSdk::MatrixRequestError.class_by_code(code)) { call_api(data['method'], args) }
        end
      end
    end
  end

  def reset_matrix_api
    stub_api_version_request
    @api = MatrixSdk::Api.new('https://example.com', protocols: :CS, autoretry: false, threadsafe: false)
  end

  def call_api(method, args)
    required_arguments_size = @api.method(method).parameters.select { |type, _| type == :req }.size

    if args.size == required_arguments_size || !args.last.is_a?(Hash)
      @api.send(method, *args)
    else
      @api.send(method, *args[0..-2], **args.last)
    end
  end
end
