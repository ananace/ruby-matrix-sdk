# Ruby Matrix SDK

A Ruby gem for easing the development of software that communicates with servers implementing the Matrix protocol.


## Usage

```ruby
api = MatrixSdk::Api.new 'https://matrix.org'

api.login user: 'example', password: 'notarealpass'
api.whoami?
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/ruby-matrix-sdk.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

