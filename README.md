# Ruby Matrix SDK

A Ruby gem for easing the development of software that communicates with servers implementing the Matrix protocol.


## Usage

```ruby
# Raw API usage
require 'matrix_sdk'

api = MatrixSdk::Api.new 'https://matrix.org'

api.login user: 'example', password: 'notarealpass'
api.whoami?
# => {:user_id=>"@example:matrix.org"}
```

```ruby
# Client wrapper
require 'matrix_sdk'

client = MatrixSdk::Client.new 'https://matrix.org'
client.login user: 'example', password: 'notarealpass' # no_sync: true

client.rooms.count
# => 5
hq = client.find_room '#matrix:matrix.org'
# => #<MatrixSdk::Room:00005592a1161528 @id="!cURbafjkfsMDVwdRDQ:matrix.org" @name="Matrix HQ" @topic="The Official Matrix HQ - please come chat here! | To support Matrix.org development: https://patreon.com/matrixdotorg | Try http://riot.im/app for a glossy web client | Looking for homeserver hosting? Check out https://upcloud.com/matrix!" @canonical_alias="#matrix:matrix.org" @aliases=["#matrix:jda.mn"] @join_rule=:public @guest_access=:can_join @event_history_limit=10>
hq.guest_access?
# => true
hq.send_text "This is an example message - don't actually do this ;)"
# => {:event_id=>"$123457890abcdef:matrix.org"}
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/ruby-matrix-sdk.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

