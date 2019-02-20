## v0.0.4 - 2019-02-20

- Adds a parameter to the client abstraction to allow retrying syncs on timeouts
- Adds support for token-based login in the client abstraction
- Adds rudimentary username and password validation in the client abstraction
- Adds MXID validation in the client abstraction
- Adds a method to discover a homeserver address based on a domain.
    - Supporting both SRV and .well-known lookups
- Adds methods from the r0.4.0 spec
- Adds support for version 3 event IDs
- Extends the connection exceptions with a specific timeout error
- Sets a series of filters in the simple client example to skip unhandled event
- Fixes an exception when null values end up in the body cleaner during debugging
- Fixes an error with CGI not being required correctly

## v0.0.3 - 2018-08-14

- Adds missing accessors for HTTP timeout
- Adds methods for checking auth status to client API
- Adds a wrapper class for API responses to ease use
- Adds option (and defaults) to store login details on registration
- Allows creating a MatrixSdk::Client off of an existing MatrixSdk::Api
- Extends event handling

- Fixes batch handling in sync
- Fixes event handling in the sample
- Removes unimplemented API methods to avoid confusion

- Plenty of documentation work

## v0.0.2 - 2018-05-11

- Fixes for multiple issues discovered after initial release
- Adds additional API methods
- Higher-level client API gets room and user abstractions

## v0.0.1 - 2018-05-06

Initial release
