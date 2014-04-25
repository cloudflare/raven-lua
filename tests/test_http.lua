require "lunit"
local socket = require "socket"
local raven = require "raven"
local cjson = require "cjson"
local posix = require "posix"

local print = print
local error = error
local string_find    = string.find
local string_sub     = string.sub
local string_match   = string.match
local os_exit        = os.exit
local random         = math.random

math.randomseed(os.time())

module("test_http", lunit.testcase)

local server = {}
local rvn
local dsn
local port = -1

function setup()
   port = random(20000, 65535)
   local sock = socket.tcp()
   assert(sock)
   assert(sock:bind("*", port))
   assert(sock:listen(64))
   server.sock = sock
end

function teardown()
   -- socket has already been closed in http_responde
   --server.sock:close()
end

local function get_dsn()
   dsn = "http://pub:secret@127.0.0.1:" .. port .. "/sentry/proj-id"
   return dsn
end


function get_body(response)
   local i = assert(string_find(response, "\n\n"))
   return string_sub(response, i + 1)
end

function http_read(sock)
   local content_len
   function get_data()
       return function() return sock:receive("*l") end
   end
   for res, err in get_data() do
      if res == "" then
         break
      end
      local s1, s2, len = string_find(res, "Content%-Length: (%d+)")
      if s1 and s2 then
         content_len = len
      end
   end
   local res, err = sock:receive(content_len)

   if not res then
      error("receive failed: " .. err)
   end
   return res
end

function http_responde(sock)
   sock:send("HTTP/1.1 200 OK\r\nServer: nginx/1.2.6\r\nDate: Mon, 10 Mar 2014 22:25:51 GMT\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Language: en-us\r\nExpires: Mon, 10 Mar 2014 22:25:51 GMT\r\nVary: Accept-Language, Cookie\r\nLast-Modified: Mon, 10 Mar 2014 22:25:51 GMT\r\nCache-Control: max-age=0\r\n\r\n{\"id\": \"02c7830aae684d0088a0616a9ed81a6b\"}")
   sock:close()
end

function test_capture_message()
   local cpid = posix.fork()
   if cpid == 0 then
      rvn = raven:new(get_dsn(), {
         tags = { foo = "bar" }
      })
      local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")
      assert_not_nil(id)
      assert_not_nil(string_match(id, "%x+"))
      os_exit()
   else
      local client = server.sock:accept()
      local json_str = http_read(client)
      --local json_str = get_body(res)
      local json = cjson.decode(json_str)
      http_responde(client)

      assert_not_nil(json)
      assert_equal("undefined", json.server_name)
      assert_equal("Sentry is a realtime event logging and aggregation platform.", json.message)
      assert_equal("lua", json.platform)
      assert_not_nil(string_match(json.culprit, "tests/test_http.lua:%d+"))
      -- Example timestamp: 2014-03-07T00:17:47
      assert_not_nil(string_match(json.timestamp, "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"))
      assert_not_nil(string_match(json.event_id, "%x+"))
      assert_equal(1, #json.tags)
      assert_equal("bar", json.tags[1].foo)
      posix.wait(cpid)
   end
end

function test_capture_exception()
   local cpid = posix.fork()
   if cpid == 0 then
      rvn = raven:new(get_dsn(), {
         tags = { foo = "bar" }
      })
      local id = rvn:captureException({{}})
      assert_not_nil(id)
      assert_not_nil(string_match(id, "%x+"))
      os_exit()
   else
      local client = server.sock:accept()
      local json_str = http_read(client)
      --local json_str = get_body(res)
      local json = cjson.decode(json_str)
      http_responde(client)

      assert_not_nil(json)
      assert_equal("undefined", json.server_name)
      assert_equal("lua", json.platform)
      assert_not_nil(string_match(json.culprit, "tests/test_http.lua:%d+"))
      -- Example timestamp: 2014-03-07T00:17:47
      assert_not_nil(string_match(json.timestamp, "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d"))
      assert_not_nil(string_match(json.event_id, "%x+"))
      assert_equal(1, #json.tags)
      assert_equal("bar", json.tags[1].foo)
      posix.wait(cpid)
   end
end
