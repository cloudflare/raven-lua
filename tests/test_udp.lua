require "lunit"
local socket = require "socket"
local raven = require "raven"
local cjson = require "cjson"

local print = print
local string_find    = string.find
local string_sub     = string.sub
local string_match   = string.match

module("test_udp", lunit.testcase)

local server = {}
local port = 29997
local dsn = "udp://pub:secret@127.0.0.1:" .. port .. "/sentry/proj-id"

function setup()
   local sock = socket.udp()
   sock:setsockname("*", port)
   server.sock = sock
end

function teardown()
   server.sock:close()
end

function get_body(response)
   local i = assert(string_find(response, "\n\n"))
   return string_sub(response, i + 1)
end

function test_capture_message()
   local rvn = raven:new(dsn)
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

function test_capture_message_with_tags()
   local rvn = raven:new(dsn)
   local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.", { tags = { abc = "def" } })
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
   assert_equal(1, #json.tags)
   assert_equal("def", json.tags[1].abc)
end

function test_capture_message_with_tags1()
   local rvn = raven:new(dsn, { tags = { foo = "bar" } })
   local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.", { tags = { abc = "def" } })
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
   assert_equal(2, #json.tags)
   assert_equal("bar", json.tags[1].foo)
   assert_equal("def", json.tags[2].abc)
end

function test_capture_message_with_level()
   local rvn = raven:new(dsn)
   local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.", { level = "info" })
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
   assert_equal("info", json.level)
end

function test_call()
   function bad_func(n)
      return not_defined_func(n)
   end

   local rvn = raven:new(dsn)
   local ok = rvn:call(bad_func, 1)

   local res = assert(server.sock:receive())
   local json_str = get_body(res)
   local json = cjson.decode(json_str)

   assert_not_nil(json)
   assert_equal("undefined", json.server_name)
   --assert_equal("tests/test_udp.lua:112: attempt to call global 'not_defined_func' (a nil value)", json.message)
   assert_equal("lua", json.platform)
   assert_not_nil(string_match(json.culprit, "not_defined_func"))
   -- Example timestamp: 2014-03-07T00:17:47
   assert_not_nil(string_match(json.timestamp, "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"))
   assert_not_nil(string_match(json.event_id, "%x+"))
   assert_false(ok)
   assert_equal("error", json.level)
   local frames = json.exception[1].stacktrace.frames
   assert_equal("not_defined_func", frames[#frames]["function"])
end
