require "lunit"
local cjson = require "cjson"
local raven = require "raven"

local string_match   = string.match
local print = print

module("sanity", lunit.testcase )

function test_parse_dsn()
   local obj = raven._parse_dsn("https://public:secret@example.com/sentry/project-id")

   assert_equal("https", obj.protocol)
   assert_equal("public", obj.public_key)
   assert_equal("secret", obj.secret_key)
   assert_equal("example.com", obj.host)
   assert_equal(80, obj.port)
   assert_equal("/sentry/", obj.path)
   assert_equal("project-id", obj.project_id)
   assert_equal("/sentry/api/project-id/store/", obj.request_uri)
   assert_equal("https://example.com/sentry/api/project-id/store/", obj.server)
   assert_not_nil(obj)
end

function test_new()
   local rvn, msg = raven:new("https://public:secret@example.com/sentry/project-id")
   assert_not_nil(rvn)
   assert_equal("Lua Sentry Client/0.4", rvn.client_id)

   -- missing public key in DSN
   local rvn1, msg = raven:new("https://secret@example.com/sentry/project-id")
   assert_nil(rvn1)
   assert_equal("Bad DSN", msg)
end

function test_get_debug_info()
   local culprit, stack = raven.get_debug_info()
   --assert_equal("tests/test_sanity.lua:33", culprit)
   assert_not_nil(string_match(culprit, "tests/test_sanity.lua:%d+"))
   assert_not_nil(stack)
end

function test_parse_host_port()
   local host, port = raven._parse_host_port("http", "127.0.0.1:29999")
   assert_equal("127.0.0.1", host)
   assert_equal(29999, port)
end

function test_parse_host_port1()
   local host, port = raven._parse_host_port("http", "somehost.com")
   assert_equal("somehost.com", host)
   assert_equal(80, port)
end

function test_parse_host_port1()
   local host, port, err = raven._parse_host_port("http", "somehost.com:abcd")
   assert_nil(host)
   assert_nil(port)
   assert_equal("illegal port: abcd", err)
end
