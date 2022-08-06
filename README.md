# Ruby Matrix SDK

A Ruby gem for easing the development of software that communicates with servers implementing the Matrix protocol.

There is a Matrix room for the discussion about usage and development at [#ruby-matrix-sdk:kittenface.studio](https://matrix.to/#/#ruby-matrix-sdk:kittenface.studio).

Live YARD documentation can be found at; https://ruby-sdk.ananace.dev

## Example usage

For more fully-featured examples, check the [examples](examples/) folder.

```ruby
# Raw API usage
require 'matrix_sdk'

api = MatrixSdk::Api.new 'https://matrix.org'

api.login user: 'example', password: 'notarealpass'
api.whoami?
# => {:user_id=>"@example:matrix.org"}

# It's possible to call arbitrary APIs as well
api.request :get, :federation_v1, '/version'
# => {:server=>{:version=>"0.28.1", :name=>"Synapse"}}
```

```ruby
# Client wrapper with login
require 'matrix_sdk'

client = MatrixSdk::Client.new 'https://example.com'
client.login 'username', 'notarealpass' #, no_sync: true

client.rooms.count
# => 5
hq = client.find_room '#matrix:matrix.org'
# => #<MatrixSdk::Room:00005592a1161528 @id="!cURbafjkfsMDVwdRDQ:matrix.org" @name="Matrix HQ" @topic="The Official Matrix HQ - please come chat here! | To support Matrix.org development: https://patreon.com/matrixdotorg | Try http://riot.im/app for a glossy web client | Looking for homeserver hosting? Check out https://upcloud.com/matrix!" @canonical_alias="#matrix:matrix.org" @aliases=["#matrix:jda.mn"] @join_rule=:public @guest_access=:can_join @event_history_limit=10>
hq.guest_access?
# => true
hq.send_text "This is an example message - don't actually do this ;)"
# => {:event_id=>"$123457890abcdef:matrix.org"}
```

```ruby
# Client wrapper with token
require 'matrix_sdk'

client = MatrixSdk::Client.new 'https://example.com'
client.api.access_token = 'thisisnotarealtoken'

# Doesn't automatically trigger a sync when setting the token directly
client.rooms.count
# => 0

client.sync
client.rooms.count
# => 5
```

```ruby
#!/bin/env ruby
# Bot DSL
require 'matrix_sdk/bot'

command :plug do
  room.send_text <<~PLUG
    The Ruby SDK is a fine method for writing applications communicating over the Matrix protocol.
    It can easily be integrated with Rails, and it supports most client/bot use-cases.
  PLUG
end
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/ruby-matrix-sdk


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

