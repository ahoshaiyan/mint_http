# MintHttp

A simple and fluent HTTP client with connection pooling capability.

MintHttp is built on top of Ruby's Net::HTTP library to provide you with the following features:

- Fluent API to build requests
- HTTP proxies support
- Client certificate support
- File uploads
- Connection pooling
- No DSLs or any other shenanigans


## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add mint_http

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install mint_http


## Basic Usage

Once you have installed the gem, require it into your Ruby code with:

```ruby
require 'mint_http'
```

Now perform a basic HTTP request:

```ruby
puts MintHttp.query(foo: 'bar').get('https://icanhazip.com').body
```

Note: when performing a request with MintHttp, you will get a [MintHttp::Response](/lib/mint_http/response.rb).


## Post Requests

MintHttp makes it easy to consume and interact with JSON APIs. You can simply make a post request as follows:

```ruby
MintHttp
  .as_json
  .accept_json
  .post('https://dummyjson.com/products/add', {
    title: 'Porsche Wallet'
  })
```

The `as_json` and `accept_json` helper methods sets `Content-Type` and `Accept` headers to `application/json`. The above
call can be re-written as:

```ruby
MintHttp
  .header('Content-Type' => 'application/json')
  .header('Accept' => 'application/json')
  .post('https://dummyjson.com/products/add', {
    title: 'Porsche Wallet'
  })
```

Note: When no content type is set, `application/json` is set by default.


## Put Requests

Like a post request, you can easily make a `PUT` request as follows:

```ruby
MintHttp.put('https://dummyjson.com/products/1', {
  title: 'Porsche Wallet'
})
```

or make a `PATCH` request

```ruby
MintHttp.patch('https://dummyjson.com/products/1', {
  title: 'Porsche Wallet'
})
```


## Delete Requests

To delete some resource, you can easily call:

```ruby
MintHttp.delete('https://dummyjson.com/products/1')
```


## Uploading Files

MintHttp makes good use of the powerful Net::HTTP library to allow you to upload files:

```ruby
MintHttp
  .as_multipart
  .with_file('upload_field', File.open('/tmp/file.txt'), 'grocery-list.txt', 'text/plain')
  .post('https://example.com/upload')
```

Note: `as_multipart` is required in order to upload files, this will set the content type to `multipart/form-data`.


## Authentication

MintHttp provides you with little helpers for common authentication schemes

### Basic Auth

```ruby
MintHttp
  .basic_auth('username', 'password')
  .get('https://example.com/secret-door')
``` 


### Bearer Auth

```ruby
MintHttp
  .bearer('super-string-token')
  .get('https://example.com/secret-door')
``` 


## Using a Proxy

Connecting through an HTTP proxy is as simple as chaining the following call:

```ruby
MintHttp
  .via_proxy('proxy.example.com', 3128, 'optional-username', 'optional-password')
  .get('https://icanhazip.com')
``` 


## Pooling Connections

When your application is communicating with external services so often, it is a good idea to keep a couple of connections
open if the target server supports that, this can save you time that is usually gone by TCP and TLS handshakes. This
is especially true when the target server is in a faraway geographical region.

MintHttp uses a pool to manage connections and make sure each connection is used by a single thread at a time. To create
a pool, simply do the following:

```ruby
pool = MintHttp::Pool.new({
  ttl: 30_000,
  idle_ttl: 4_000,
  size: 10,
  usage_limit: 500,
  timeout: 500,
})
```

This will create a new pool with the following properties:

- Allow a connection to be open for a maximum of 30 seconds defined by `ttl`.
- If a connection is not used within 4 seconds of the last use then it is considered expired, defined by `idle_ttl` (default 5 seconds).
- Only hold a maximum of 10 connections, if an 11th thread tries to acquire a connection, it will block until there is one available or timeout is reached. Idle connections to other hosts are closed to make room. When the timeout is reached `MintHttp::PoolTimeoutError` (a `RuntimeError`) is raised and the request is not sent.
- A connection may be only used for 500 requests, then it should be closed. This is defined by `usage_limit`.

> Note: keep `idle_ttl` lower than the keep-alive timeout of the servers you call (5 seconds for Node.js and Apache,
> 60 seconds for AWS ALB, 75 seconds for nginx). Otherwise the server may close a connection just as MintHttp reuses it,
> and the request fails with a `MintHttp::ConnectionError`.

To retry those failures, create the pool with `retry_stale: true`. A request that fails on a reused connection before
any response byte arrived is then sent once more on a new connection, but only when it is safe to send again: `GET`,
`HEAD` and `OPTIONS` requests, or requests carrying an `Idempotency-Key` (or `X-Idempotency-Key`) header.

```ruby
pool = MintHttp::Pool.new({ idle_ttl: 4_000, retry_stale: true })
```

Once you have created a pool, you can use it in your requests as following:

```ruby
MintHttp
  .use_pool(pool)
  .get('https://example.com')
```

A single pool can be used for multiple endpoints, as MintHttp will logically separate connections based on hostname, port,
scheme, client certificate, proxy, and other variables.

> Note: it is possible to use only a single pool for the entire application.

> Note: The Pool object is thread-safe and fork-safe: connections inherited from a parent process are discarded.

> Note: A request interrupted by `Timeout.timeout`, `Thread#raise` or similar never returns its connection to the
> pool, so the next request cannot receive the interrupted request's response. Requests respect the caller's
> `Thread.handle_interrupt` mask.


## The Response Object

Each HTTP request will return a [response](/lib/mint_http/response.rb) object when a response is received from the server regardless of the status code.

You can chain the `raise!` call after the request to make MintHttp throw an exception when a `4xx` ot `5xx` error is returned.
Otherwise the same response object is returned. 

```ruby
MintHttp.get('https://example.com').raise!
```

When the connection closes before the whole body arrived, the truncated body is returned. Chain `raise_on_truncated_body`
to raise `MintHttp::ProtocolError` instead:

```ruby
MintHttp.raise_on_truncated_body.get('https://example.com')
```


## Missing Features

There are a couple of features that are coming soon, these include:

- Retrying Requests
- Middlewares


## Credit

This library was inspired by Laravel's `Http` wrapper over `GuzzleHttp`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ahoshaiyan/mint_http.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
