require "lunit"
local socket = require "socket"
local raven = require "raven"
local cjson = require "cjson"
local posix = require "posix"
local ssl = require "ssl"

local print = print
local error = error
local string_find    = string.find
local string_sub     = string.sub
local string_match   = string.match
local os_exit        = os.exit
local random         = math.random

-- generate HTTPS certs:
-- create CA:  openssl req -x509 -newkey rsa:4096 -keyout ca.key.pem -out ca.cert.pem -days 1000000 -nodes
-- create CSR: openssl req -newkey rsa:4096 -keyout key.pem -out cert.csr.pem -nodes
-- sign CSR:   openssl x509 -req -in cert.csr.pem -CA ca.cert.pem -CAkey ca.key.pem -CAcreateserial -out cert.pem -days 1000000

math.randomseed(os.time())

module("test_https", lunit.testcase)

local server = {}
local rvn
local dsn
local port = -1

local server_sslparams = {
  mode = "server",
  protocol = "tlsv1_2",
  key = "./tests/certs/key.pem",
  certificate = "./tests/certs/cert.pem",
  verify = "none",
  options = "all"
}


function setup()
   port = random(20000, 65535)
   --port = 10000
   local sock = socket.tcp()
   assert(sock)
   assert(sock:bind("*", port))
   assert(sock:listen(64))
   server.sock = sock
end


function teardown()
   -- socket has already been closed in http_respond
   --server.sock:close()
end

local function get_dsn()
   dsn = "https://pub:secret@127.0.0.1:" .. port .. "/sentry/proj-id"
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

function http_respond(sock)
   sock:send("HTTP/1.1 200 OK\r\nServer: nginx/1.2.6\r\nDate: Mon, 10 Mar 2014 22:25:51 GMT\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Language: en-us\r\nExpires: Mon, 10 Mar 2014 22:25:51 GMT\r\nVary: Accept-Language, Cookie\r\nLast-Modified: Mon, 10 Mar 2014 22:25:51 GMT\r\nCache-Control: max-age=0\r\n\r\n{\"id\": \"02c7830aae684d0088a0616a9ed81a6b\"}")
   sock:close()
end

function test_validate_cert_ok()
   local cpid = posix.fork()
   if cpid == 0 then
      local client = server.sock:accept()
      client = ssl.wrap(client, server_sslparams)
      assert(client:dohandshake())
      local json_str = http_read(client)
      local json = cjson.decode(json_str)
      http_respond(client)
      os_exit()
   else
      rvn = raven:new(get_dsn(), {
         tags = { foo = "bar" },
         cacert = "./tests/certs/ca.cert.pem",
      })
      local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")
      assert_not_nil(id)
      assert_not_nil(string_match(id, "%x+"))
   end
end

function test_validate_cert_failure()
   local cpid = posix.fork()
   if cpid == 0 then
      local client = server.sock:accept()
      client = ssl.wrap(client, server_sslparams)
      local ok, err = client:dohandshake()
      assert(not ok)
      os_exit()
   else
      -- load the certificate for another CA, it must fail
      rvn = raven:new(get_dsn(), {
         tags = { foo = "bar" },
         cacert = "./tests/certs/wrongca.cert.pem",
      })
      local ok, err = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")
      assert_nil(ok)
      assert_equal('certificate verify failed', err)
   end
end

function test_no_validate_cert()
   local cpid = posix.fork()
   if cpid == 0 then
      local client = server.sock:accept()
      client = ssl.wrap(client, server_sslparams)
      assert(client:dohandshake())
      local json_str = http_read(client)
      local json = cjson.decode(json_str)
      http_respond(client)
      os_exit()
   else
      rvn = raven:new(get_dsn(), {
         tags = { foo = "bar" },
         verify_ssl = false,
      })
      local id = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")
      assert_not_nil(id)
      assert_not_nil(string_match(id, "%x+"))
   end
end

