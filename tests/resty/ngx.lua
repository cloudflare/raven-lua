-- Copyright (c) 2014-2017 CloudFlare, Inc.

describe("nginx-lua network layer", function()
    -- monkey patch the ngx.get_phase function
    local phase_override = nil
    do
        local real_get_phase = ngx.get_phase
        function ngx.get_phase()
            return phase_override or real_get_phase()
        end
    end

    local ngx_sender = require 'raven.senders.ngx'

    local shared -- shared state between the request handler and the test harness
    before(function()
        phase_override = nil
        shared = {}
        package.loaded.shared = shared
    end)

    test("send an event over HTTP", function()
        local sender = assert(ngx_sender.new({ dsn = "http://public-key:secret-key@127.0.0.1:15514/sentry/myproject" }))
        local payload = '{ "foo": "bar" }'
        assert(sender:send(payload))

        assert_equal("POST", shared.method)
        assert_equal("/sentry/api/myproject/store/", shared.uri)
        assert_equal(tostring(#payload), shared.headers["content-length"])
        assert_type(shared.headers["x-sentry-auth"], "string")
        assert_equal(shared.payload, payload)
    end)

    test("send an event over HTTPS (no cert verification)", function()
        local sender = assert(ngx_sender.new({ dsn = "https://public-key:secret-key@127.0.0.1:15515/sentry/myproject" }))
        local payload = '{ "foo": "bar" }'
        assert(sender:send(payload))

        assert_equal("POST", shared.method)
        assert_equal("/sentry/api/myproject/store/", shared.uri)
        assert_equal(tostring(#payload), shared.headers["content-length"])
        assert_type(shared.headers["x-sentry-auth"], "string")
        assert_equal(shared.payload, payload)
    end)

    test("send an event over HTTPS (check certificate)", function()
        local sender = assert(ngx_sender.new({
            dsn = "https://public-key:secret-key@localhost:15515/sentry/myproject",
            verify_ssl = true,
            target = "127.0.0.1",
        }))
        local payload = '{ "foo": "bar" }'
        assert(sender:send(payload))

        assert_equal("POST", shared.method)
        assert_equal("/sentry/api/myproject/store/", shared.uri)
        assert_equal(tostring(#payload), shared.headers["content-length"])
        assert_type(shared.headers["x-sentry-auth"], "string")
        assert_equal(shared.payload, payload)
    end)

    test("send an event over HTTPS (certificate error)", function()
        local sender = assert(ngx_sender.new({
            dsn = "https://public-key:secret-key@example.com:15515/sentry/myproject",
            verify_ssl = true,
            target = "127.0.0.1",
        }))

        local ok, err = sender:send('')
        assert_nil(ok)
        assert_type(err, 'string')
    end)

    test("send an event while sockets are not available", function()
        phase_override = 'init'

        local sender = assert(ngx_sender.new({ dsn = "http://public-key:secret-key@127.0.0.1:15514/sentry/myproject" }))
        local payload = '{ "foo": "bar" }'
        assert(sender:send(payload))

        -- check the issue has not been sent yet
        assert_nil(next(shared))

        ngx.sleep(0.01) -- yield the current thread, allowing the message to be sent

        assert_equal("POST", shared.method)
        assert_equal("/sentry/api/myproject/store/", shared.uri)
        assert_equal(tostring(#payload), shared.headers["content-length"])
        assert_type(shared.headers["x-sentry-auth"], "string")
        assert_equal(shared.payload, payload)

        -- send another message
        local payload = '{ "foo": "baz" }'
        assert(sender:send(payload))
        ngx.sleep(0.01)

        assert_equal("POST", shared.method)
        assert_equal("/sentry/api/myproject/store/", shared.uri)
        assert_equal(tostring(#payload), shared.headers["content-length"])
        assert_type(shared.headers["x-sentry-auth"], "string")
        assert_equal(shared.payload, payload)

    end)
end)
