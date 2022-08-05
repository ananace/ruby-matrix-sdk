require 'test_helper'

class BotTest < Test::Unit::TestCase
  class ExampleBot < MatrixSdk::Bot::Base
    set :testing, true

    command :test do |arg, arg2 = nil|
      # ARG [ARG2]
      bot.send :test_executed
    end

    command :test_arr do |*args|
      # [ARGS...]
      bot.send :test_arr_executed
    end

    command :test_only, only: :dm do
      bot.send :test_only
    end

    command :test_event do
      bot.send :test_event, event.event_id
    end
  end

  def setup
    ::Net::HTTP.any_instance.expects(:request).never

    @http = mock
    @http.stubs(:active?).returns(true)

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :CS
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)

    @client = MatrixSdk::Client.new @api
    @client.stubs(:mxid).returns('@alice:example.com')

    @id = '!room:example.com'
    @client.send :ensure_room, @id
    @room = @client.rooms.first

    @bot = ExampleBot.new @client

    matrixsdk_add_api_stub
  end

  def test_configuration
    assert ExampleBot.testing?
    assert ExampleBot.command? 'help'
    refute ExampleBot.command? 'help', ignore_inherited: true
    assert ExampleBot.command? 'test'
    assert ExampleBot.command? 'test_arr'

    # Check sane default configuration
    assert ExampleBot.accept_invites?
    assert ExampleBot.ignore_own?
    refute ExampleBot.require_fullname?
    refute ExampleBot.store_sync_token?
    assert ExampleBot.threadsafe?
    refute ExampleBot.login?
    refute ExampleBot.logging?

    # Check generated configuration
    assert ExampleBot.bot_name?
    assert_equal 'rake_test_loader', ExampleBot.bot_name

    handlers = ExampleBot.instance_variable_get :@handlers

    assert_equal 'ARG [ARG2]', handlers['test'].data[:args]
    assert_equal '[ARGS...]', handlers['test_arr'].data[:args]
    assert_equal '', handlers['test_only'].data[:args]
  end

  def test_handling
    @room.stubs(:dm?).returns(false)

    ev = {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!not_a_command'
      }
    }

    refute @bot.command_allowed? 'not_a_command', ev
    @bot.send :_handle_event, ev

    ev = {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_andmore'
      }
    }

    refute @bot.command_allowed? 'test_andmore', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_executed).once
    @bot.expects(:test_arr_executed).never

    ev = {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test'
      }
    }

    assert @bot.command_allowed? 'test', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_executed).never
    @bot.expects(:test_arr_executed).once

    ev = {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_arr'
      }
    }

    assert @bot.command_allowed? 'test_arr', ev
    @bot.send :_handle_event, ev

    ev = {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test_only'
      }
    }

    @bot.expects(:test_only).never

    refute @bot.command_allowed? 'test_only', ev
    @bot.send :_handle_event, ev

    @room.stubs(:dm?).returns(true)

    @bot.expects(:test_only).once

    assert @bot.command_allowed? 'test_only', ev
    @bot.send :_handle_event, ev

    @room.stubs(:dm?).returns(false)

    @bot.expects(:test_executed).never

    ev = {
      sender: '@alice:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!test'
      }
    }

    assert @bot.command_allowed? 'test', ev
    @bot.send :_handle_event, ev

    @bot.class.stubs(:ignore_own?).returns(false)

    @bot.expects(:test_executed).once

    assert @bot.command_allowed? 'test', ev
    @bot.send :_handle_event, ev

    @bot.expects(:test_event).with('$someevent').once

    ev = {
      sender: '@bob:example.com',
      room_id: @id,
      event_id: '$someevent',
      content: {
        msgtype: 'm.text',
        body: '!test_event'
      }
    }

    assert @bot.command_allowed? 'test_event', ev
    @bot.send :_handle_event, ev
  end

  def test_builtin_help
    @room.stubs(:dm?).returns(false)

    @room.expects(:send_notice).with(<<~MSG.strip)
      Usage:

      !rake_test_loader help [COMMAND] - Shows this help text
      !rake_test_loader test ARG [ARG2]
      !rake_test_loader test_arr [ARGS...]
      !rake_test_loader test_event
    MSG

    @bot.send :_handle_event, {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help'
      }
    }

    @room.expects(:send_notice).with(<<~MSG.strip)
      Help for help;
      !rake_test_loader help [COMMAND] - Shows this help text
        For commands that take multiple arguments, you will need to use quotes around spaces
        E.g. !login "my username" "this is not a real password"
    MSG

    @bot.send :_handle_event, {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help help'
      }
    }

    @room.stubs(:dm?).returns(true)

    @room.expects(:send_notice).with(<<~MSG.strip)
      Usage:

      !help [COMMAND] - Shows this help text
      !test ARG [ARG2]
      !test_arr [ARGS...]
      !test_only
      !test_event
    MSG

    @bot.send :_handle_event, {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help'
      }
    }

    @room.expects(:send_notice).with(<<~MSG.strip)
      Help for help;
      !help [COMMAND] - Shows this help text
        For commands that take multiple arguments, you will need to use quotes around spaces
        E.g. !login "my username" "this is not a real password"
    MSG

    @bot.send :_handle_event, {
      sender: '@bob:example.com',
      room_id: @id,
      content: {
        msgtype: 'm.text',
        body: '!help help'
      }
    }
  end
end
