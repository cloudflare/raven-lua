-- vim: st=4 sts=4 sw=4 et:
-- Copyright (c) 2014-2017 CloudFlare, Inc.

package.path = "./?/init.lua;" .. package.path

describe("Sentry error reporter", function()
    local raven = require "raven"
    local test_sender = require "raven.senders.test"
    local culprit_prefix = debug.getinfo(1).short_src .. ":"
    local filename = debug.getinfo(1).source:sub(2) -- remove the leading "@"

    test("send message", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
        }

        rvn:capture_message("hello")

        assert_equal(#sender.events, 1)
        local ev = sender.events[1]
        assert_type(ev, "table")
        assert_equal(ev.logger, "root")
        assert_equal(ev.event_id:match(string.rep("%x", 32)), ev.event_id)
        assert_equal(ev.platform, "lua")
        assert_equal(ev.culprit:sub(1, #culprit_prefix), culprit_prefix)
        assert_equal(ev.level, "error")
        assert_equal(ev.message, "hello")
        assert_type(ev.timestamp, "string")
        assert_equal(ev.server_name, "undefined") -- no getter specified
    end)

    test("send exceptions", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
        }

        rvn:call(function() error "boom" end)

        assert_equal(#sender.events, 1)
        local ev = sender.events[1]
        assert_type(ev, "table")
        assert_equal(ev.logger, "root")
        assert_equal(ev.event_id:match(string.rep("%x", 32)), ev.event_id)
        assert_equal(ev.platform, "lua")
        -- FIXME: maybe we want to make error and assert special cases
        assert_equal(ev.culprit, "error")
        assert_equal(ev.level, "error")
        assert_type(ev.timestamp, "string")
        assert_equal(ev.server_name, "undefined") -- no getter specified
        assert_equal(ev.message:match(culprit_prefix .. ".+boom$"), ev.message)
        -- check exception
        assert_equal(ev.exception[1].value, ev.message)
        local trace = ev.exception[1].stacktrace.frames
        assert_equal(trace[#trace]['function'], 'error')
        assert_equal(trace[#trace-1].filename, filename)
        --]]
    end)

    test("custom reporter", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
        }

        raven.get_server_name = function()
            return "myserver"
        end

        rvn:capture_message("hello")
        assert_equal(sender.events[1].server_name, "myserver")
    end)

    test("default tags", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
            tags = { type="foobar", client_ip="1.2.3.4" },
        }

        rvn:capture_message("hello")

        local ev = sender.events[1]
        assert_equal("foobar", ev.tags.type)
        assert_equal("1.2.3.4", ev.tags.client_ip)
    end)
    --print(require("ml").tstring(sender.events[1], "  "))
    test("tag union", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
            tags = { type="foobar", client_ip="1.2.3.4" },
        }

        rvn:capture_message("hello", { tags = { client_ip="::1", foo="bar", another="tag" } })
        rvn:capture_message("bye", { tags = { client_ip="::2", foo="baz" } })
        assert_equal(#sender.events, 2)

        local ev = sender.events[1]
        assert_equal("foobar", ev.tags.type)
        assert_equal("::1", ev.tags.client_ip)
        assert_equal("bar", ev.tags.foo)
        assert_equal("tag", ev.tags.another)

        ev = sender.events[2]
        assert_equal("foobar", ev.tags.type)
        assert_equal("::2", ev.tags.client_ip)
        assert_equal("baz", ev.tags.foo)
        assert_nil(ev.tags.another)
    end)

    test("custom settings", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
            level = "notice",
            logger = "custom",
        }

        rvn:capture_message("hello")
        local ev = sender.events[1]
        assert_equal(ev.level, "notice")
        assert_equal(ev.logger, "custom")
    end)

    test("generated catcher", function()
        local sender = test_sender.new()
        local rvn = raven.new {
            sender = sender,
        }

        local catcher = rvn:gen_capture_err()
        local ok, ev = xpcall(function()
            error 'boom'
        end, catcher)

        assert_equal(false, ok)
        assert_type(ev, 'table')
        assert_match('.*boom.*', ev.message)
        assert_match('.*boom.*', ev.exception[1].value)
        assert_type(ev.exception[1].stacktrace.frames, 'table')
        -- check that the __tostring metamethod does its job
        assert_match('.*boom.*', tostring(ev))
    end)

    test("extra data", function()
        local sender = test_sender.new()
        local rvn = raven.new { sender = sender, extra = { some="data" } }

        rvn:capture_message("hello", { extra = { client_ip="::1", foo="bar" } })
        rvn:capture_message("bye", { extra = { client_ip="::2", foo="baz" } })
        assert_equal(#sender.events, 2)

        local ev = sender.events[1]
        assert_equal("::1", ev.extra.client_ip)
        assert_equal("bar", ev.extra.foo)
        assert_equal("data", ev.extra.some)

        ev = sender.events[2]
        assert_equal("::2", ev.extra.client_ip)
        assert_equal("baz", ev.extra.foo)
        assert_equal("data", ev.extra.some)
    end)
end)
