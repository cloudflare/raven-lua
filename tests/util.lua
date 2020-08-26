-- vim: st=4 sts=4 sw=4 et:
-- Copyright (c) 2014-2017 CloudFlare, Inc.

describe("util functions", function()
    local util = require "raven.util"
    test("DSN parsing", function()
        local out = util.parse_dsn("https://public:secret@sentry.example.com/1")
        assert_equal(out.protocol, "https")
        assert_equal(out.public_key, "public")
        assert_equal(out.secret_key, "secret")
        assert_equal(out.host, "sentry.example.com")
        assert_equal(out.port, 443)
        assert_equal(out.project_id, "1")
        -- aux fields
        assert_equal(out.long_host, "sentry.example.com")
        assert_equal(out.request_uri, "/api/1/store/")
        assert_equal(out.server, "https://sentry.example.com:443/api/1/store/")

        -- plain HTTP
        local out = util.parse_dsn("http://public:secret@sentry.example.com/1")
        assert_equal(out.protocol, "http")
        assert_equal(out.public_key, "public")
        assert_equal(out.secret_key, "secret")
        assert_equal(out.host, "sentry.example.com")
        assert_equal(out.port, 80)
        assert_equal(out.project_id, "1")
        -- aux fields
        assert_equal(out.long_host, "sentry.example.com")
        assert_equal(out.request_uri, "/api/1/store/")
        assert_equal(out.server, "http://sentry.example.com:80/api/1/store/")

        -- force port
        local out = util.parse_dsn("http://public:secret@sentry.example.com:1234/1")
        assert_equal(out.protocol, "http")
        assert_equal(out.public_key, "public")
        assert_equal(out.secret_key, "secret")
        assert_equal(out.host, "sentry.example.com")
        assert_equal(out.port, 1234)
        assert_equal(out.project_id, "1")
        -- aux fields
        assert_equal(out.long_host, "sentry.example.com:1234")
        assert_equal(out.request_uri, "/api/1/store/")
        assert_equal(out.server, "http://sentry.example.com:1234/api/1/store/")

        -- new auth-style DSN
        local out = util.parse_dsn("http://public@sentry.example.com/1")
        assert_equal(out.protocol, "http")
        assert_equal(out.public_key, "public")
        assert_equal(out.secret_key, nil)
        assert_equal(out.host, "sentry.example.com")
        assert_equal(out.port, 80)
        assert_equal(out.project_id, "1")
        -- aux fields
        assert_equal(out.long_host, "sentry.example.com")
        assert_equal(out.request_uri, "/api/1/store/")
        assert_equal(out.server, "http://sentry.example.com:80/api/1/store/")
    end)

    test("Auth header generation", function()
        local dsn = util.parse_dsn("https://public:secret@sentry.example.com/1")
        local auth = util.generate_auth_header(dsn)
        assert_equal(auth:match("Sentry .+"), auth)
        local params = {}
        for k, v in auth:gmatch("(%S-)=([^,]+)") do
            params[k] = v
        end

        assert_equal(params.sentry_version, "6")
        assert_equal(params.sentry_key, "public")
        assert_equal(params.sentry_secret, "secret")
        assert_type(params.sentry_client, "string")
        assert_type(params.sentry_timestamp, "string")

        -- new auth-style DSN
        local dsn = util.parse_dsn("https://public@sentry.example.com/1")
        local auth = util.generate_auth_header(dsn)
        assert_equal(auth:match("Sentry .+"), auth)
        local params = {}
        for k, v in auth:gmatch("(%S-)=([^,]+)") do
            params[k] = v
        end

        assert_equal(params.sentry_version, "6")
        assert_equal(params.sentry_key, "public")
        assert_equal(params.sentry_secret, nil)
        assert_type(params.sentry_client, "string")
        assert_type(params.sentry_timestamp, "string")
    end)
end)
