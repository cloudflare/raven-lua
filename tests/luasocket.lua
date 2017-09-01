-- vim: st=4 sts=4 sw=4 et:
-- Copyright (c) 2014-2017 CloudFlare, Inc.


HTTP_RESPONSE =
    "HTTP/1.1 200 OK\r\n" ..
    "Server: yolo-http/0.0.0\r\n" ..
    "Content-Type: application/json\r\n" ..
    "Connection: close\r\n" ..
    "\r\n" ..
    "{\"id\": \"02c7830aae684d0088a0616a9ed81a6b\"}"

describe("Luasocket network layer", function()
    local socket_sender = require "raven.senders.luasocket"
    local socket = require "socket"
    local posix = require "posix"
    local cjson = require "cjson"
    local PORT = 15514
    local server

    ----------------------------
    -- stub HTTP server logic --
    ----------------------------

    local function http_read(sock)
        assert(sock:settimeout(1))
        local l = assert(sock:receive('*l'))
        local method, uri = assert(l:match('^(%w+)%s+(%S+)%s+HTTP/1..$'))
        local headers = {}
        local body
        while true do
            local l = assert(sock:receive('*l'))
            if l == '' then break end
            local k, v = assert(l:match('^(.-):%s+(.+)$'))
            headers[k:lower()] = v
        end

        if headers['content-length'] then
            body = sock:receive(assert(tonumber(headers['content-length'])))
        end

        -- send the read request to the test harness
        io.stdout:write(cjson.encode({
            method = method,
            uri = uri,
            headers = headers,
            body = body
        }))
        io.stdout:flush()
        return true
    end

    local function http_respond(sock)
        assert(sock:send(HTTP_RESPONSE))
    end

    after(function()
        local status, code = assert(posix.pclose(server))
        assert_equal("exited", status)
        assert_equal(0, code)
    end)

    -----------------------
    -- actual unit tests --
    -----------------------

    describe("Plain HTTP tests", function()
        before(function()
            server = posix.popen(function()
                local server = assert(socket.tcp())
                assert(server:setoption('reuseaddr', true))
                assert(server:settimeout(1))
                assert(server:bind("127.0.0.1", PORT))
                assert(server:listen(64))
                local client = assert(server:accept())
                local req = http_read(client)
                http_respond(client)
                return 0
            end, 'r')
            posix.sleep(0.1)
        end)

        test("send an event over HTTP", function()
            local sender = assert(socket_sender.new({ dsn = "http://public-key:secret-key@127.0.0.1:"..PORT.."/sentry/myproject" }))
            local payload = '{ "foo": "bar" }'
            assert(sender:send(payload))

            -- check that the server got the expected data
            local data = assert(cjson.decode(assert(posix.read(server.fd, 16*1024))))
            assert_equal("POST", data.method)
            assert_equal("/sentry/api/myproject/store/", data.uri)
            assert_equal(tostring(#payload), data.headers["content-length"])
            assert_type(data.headers["x-sentry-auth"], "string")
            assert_equal(data.body, payload)
        end)
    end)

    describe("HTTPS tests", function()
        local ssl = require "ssl"
        local server_sslparams = {
            mode = "server",
            protocol = "tlsv1_2",
            key = "./tests/certs/key.pem",
            certificate = "./tests/certs/cert.pem",
            verify = "none",
            options = "all"
        }

        before(function()
            server = posix.popen(function()
                local server = assert(socket.tcp())
                assert(server:settimeout(1))
                assert(server:setoption('reuseaddr', true))
                assert(server:bind("127.0.0.1", PORT))
                assert(server:listen(64))
                local client = assert(server:accept())
                client = ssl.wrap(client, server_sslparams)
                local ok, err = client:dohandshake()
                if not ok then
                    client:close()
                    return
                end
                local req = http_read(client)
                http_respond(client)
                return 0
            end, 'r')
            posix.sleep(0.1)
        end)

        test("send an event over HTTPS (no cert verification)", function()
            local sender = assert(socket_sender.new({ dsn = "https://public-key:secret-key@127.0.0.1:"..PORT.."/sentry/myproject" }))
            local payload = '{ "foo": "bar" }'
            assert(sender:send(payload))

            local data = assert(cjson.decode(assert(posix.read(server.fd, 16*1024))))
            assert_equal("POST", data.method)
            assert_equal("/sentry/api/myproject/store/", data.uri)
            assert_equal(tostring(#payload), data.headers["content-length"])
            assert_type(data.headers["x-sentry-auth"], "string")
            assert_equal(data.body, payload)
        end)

        test("send an event over HTTPS (check certificate)", function()
            local sender = assert(socket_sender.new({
                dsn = "https://public-key:secret-key@localhost:"..PORT.."/sentry/myproject",
                verify_ssl = true,
                cafile = "./tests/certs/ca.cert.pem",
            }))
            local payload = '{ "foo": "bar" }'
            assert(sender:send(payload))

            local data = assert(cjson.decode(assert(posix.read(server.fd, 16*1024))))
            assert_equal("POST", data.method)
            assert_equal("/sentry/api/myproject/store/", data.uri)
            assert_equal(tostring(#payload), data.headers["content-length"])
            assert_type(data.headers["x-sentry-auth"], "string")
            assert_equal(data.body, payload)
        end)

        test("send an event over HTTPS (certificate error)", function()
            local sender = assert(socket_sender.new({
                dsn = "https://public-key:secret-key@localhost:"..PORT.."/sentry/myproject",
                verify_ssl = true,
                cafile = "./tests/certs/wrongca.cert.pem",
            }))

            local ok, err = sender:send('{}')
            assert_nil(ok)
            assert_type(err, 'string')
        end)
    end)
end)
