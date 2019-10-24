require 'test_helper'

class ApiCSVerificationTest < Test::Unit::TestCase
  def setup
    @http = mock
    @http.stubs(:active?).returns(true)

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :CS
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)

    @fixture = Psych.load_file('test/fixtures/cs_api_methods.yaml')

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

  def mock_response(code, body)
    response = mock
    response.stubs(:is_a?).returns do |klass|
      Net::HTTPResponse::CODE_TO_OBJ[code.to_s] == klass
    end
    response.stubs(:code).returns(code)
    response.stubs(:body).returns(body)
    response
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

      # puts function
      if data.key? 'requests'
        data['requests'].each do |request|
          response = request.fetch('response', {})
          @api.expects(:request).with do |method, _api, path, options|
            options ||= {}
            assert_equal request['method'], method if request.key?('method')
            assert_equal request['path'], path if request.key?('path')
            assert_equal request['query'], options[:query] if request.key?('query')
            assert_equal request['body'], options[:body] if request.key?('body')

            if request.key? 'headers'
              request['headers'].each do |header, expected|
                assert_equal expected, options[:headers][header]
              end
            end

            true
          end.returns(response)

          assert @api.send(data['method'], *request['args'].deep_symbolize_keys)
          @api.unstub(:request)
        end
      end

      next unless data.key? 'results'

      data['results'].each do |code, body|
        @http.expects(:request).returns(mock_response(code, body))

        args = if data.key? 'requests'
                 data['requests'].first['args'].deep_symbolize_keys
               else
                 []
               end

        if code.to_s[0] == 2
          assert !@api.send(data['method'], *args).nil?
        else
          assert_raises(MatrixSdk::MatrixRequestError.class_by_code(code)) { @api.send(data['method'], *args) }
        end

        @http.unstub(:request)
      end
    end
  end
end
