require "lunit"
local socket = require "socket"
local raven = require "raven"
local cjson = require "cjson"

local print = print
local string_find    = string.find
local string_sub     = string.sub
local string_match   = string.match

module("sanity", lunit.testcase)

local server = {}
local rvn
local port = 29999
local dsn = "udp://pub:secret@127.0.0.1:" .. port .. "/sentry/proj-id"

function setup()
   local sock = socket.udp()
   sock:setsockname("*", port)
   server.sock = sock
   rvn = raven:new(dsn)
end

function teardown()
   server.sock:close()
end

function get_body(response)
   local i = assert(string_find(response, "\n\n"))
   return string_sub(response, i + 1)
end

function test_capture_message()
   local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")
   local res = assert(server.sock:receive())
   local json_str = get_body(res)
   local json = cjson.decode(json_str)

   assert_not_nil(json)
   assert_equal("undefined", json.server_name)
   assert_equal("Sentry is a realtime event logging and aggregation platform.", json.message)
   assert_equal("lua", json.platform)
   assert_not_nil(string_match(json.culprit, "tests/test_udp.lua:%d+"))
   -- Example timestamp: 2014-03-07T00:17:47
   assert_not_nil(string_match(json.timestamp, "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"))
   assert_not_nil(string_match(json.event_id, "%x+"))
   assert_not_nil(string_match(id, "%x+"))
end
