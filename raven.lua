-------------------------------------------------------------------
-- raven.lua: a Lua Raven client used to send errors to
-- <a href="http://sentry.readthedocs.org/en/latest/index.html">Sentry</a>
--
-- According to client development guide
--
--    The following items are expected of production-ready clients:
--    <ul>
--    <li> DSN configuration √</li>
--    <li> Graceful failures (e.g. Sentry server unreachable) √</li>
--    <li> Scrubbing w/ processors</li>
--    <li> Tag support √</li>
--    </ul>
--
-- To test a DSN configuration:
-- <pre>$ lua raven.lua test [DSN]</pre>
--
-- @author JGC <jgc@cloudflare.com>
-- @author Jiale Zhi <vipcalio@gmail.com>
-- @copyright (c) 2013-2014, CloudFlare, Inc.
--------------------------------------------------------------------

--pcall(require("luacov"))
local json = require("cjson")
local debug = require("debug")

local ngx = ngx
local arg = arg
local setmetatable = setmetatable
local tostring = tostring
local xpcall = xpcall

local version        = "0.4.1"
local os_date        = os.date
local os_time        = os.time
local debug_getinfo  = debug.getinfo
local math_random    = math.random
local json_encode    = json.encode
local string_format  = string.format
local string_match   = string.match
local string_find    = string.find
local string_sub     = string.sub
local table_insert   = table.insert

local debug = false

local socket
local ssl
local catcher_trace_level = 4
if not ngx then
   local ok, luasocket = pcall(require, "socket")
   if not ok then
      error("No socket library found, you need ngx.socket or luasocket.")
   end
   local ok, luassl = pcall(require, "ssl")
   if ok then
      ssl = luassl
   end
   socket = luasocket
else
   socket = ngx.socket
end

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local ok, clear_tab = pcall(require, "table.clear")
if not ok then
   clear_tab = function(tab)
      for k, v in pairs(tab) do
         tab[k] = nil
      end
   end
end

local function log(...)
   if not ngx then
      print(...)
   else
      ngx.log(ngx.NOTICE, ...)
   end
end

-- backup logging when cannot send data to Sentry
local function errlog(...)
   if not ngx then
      print("[ERROR]", ...)
   else
      ngx.log(ngx.ERR, ...)
   end
end

local _json = {}

local _exception = { {} }

local _M = {}

local mt = {
   __index = _M,
}

math.randomseed(os_time())

-- hexrandom: returns a random number in hex with the specified number
-- of digits
local function hexrandom(digits)
   local s = ''
   for i=1,digits do
      s = s .. string_format("%0x", math_random(1,16)-1)
   end
   return s
end

-- uuid4: create a UUID in Version 4 format as a string albeit without
-- the -s separating fields
local function uuid4()
   return string_format("%s4%s8%s%s", hexrandom(12), hexrandom(3),
      hexrandom(3), hexrandom(12))
end

-- iso8601: returns the current date/time in ISO8601 format with no
-- timezone indicator but in UTC
local function iso8601()

   -- The ! forces os_date to return UTC. Don't change this to use
   -- os.date/os.time to format the date/time because timezone
   -- problems occur

   local t = os_date("!*t")
   return string_format("%04d-%02d-%02dT%02d:%02d:%02d",
      t["year"], t["month"], t["day"], t["hour"], t["min"], t["sec"])
end

-- _get_server_name: returns current nginx server name if ngx_lua is used.
-- If ngx_lua is not used, returns "undefined"
local function _get_server_name()
   return ngx and ngx.var.server_name or "undefined"
end

local function backtrace(level)
   local frames = {}

   level = level + 1

   while true do
      local info = debug_getinfo(level, "Snl")
      if not info then
         break
      end

      table_insert(frames, 1, {
         filename = info.short_src,
         ["function"] = info.name,
         lineno = info.currentline,
      })

      level = level + 1
   end
   return { frames = frames }
end

-- _parse_host_port: parse long host ("127.0.0.1:2222")
-- to host ("127.0.0.1") and port (2222)
local function _parse_host_port(protocol, host)
   local i = string_find(host, ":")
   if not i then
      -- TODO
      return host, nil
   end

   local port_str = string_sub(host, i + 1)
   local port = tonumber(port_str)
   if not port then
      return nil, nil, "illegal port: " .. port_str
   end

   return string_sub(host, 1, i - 1), port
end
_M._parse_host_port = _parse_host_port

-- _parse_dsn: gets protocol, public_key, secret_key, host, port, path and
-- project from DSN
local function _parse_dsn(dsn, obj)
   if not obj then
      obj = {}
   end

   assert(type(obj) == "table")

   -- '{PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}'
   obj.protocol, obj.public_key, obj.secret_key, obj.long_host,
         obj.path, obj.project_id =
         string_match(dsn, "^([^:]+)://([^:]+):([^@]+)@([^/]+)(.*/)(.+)$")

   if obj.protocol and obj.public_key and obj.secret_key and obj.long_host
         and obj.project_id then

      local host, port, err = _parse_host_port(obj.protocol, obj.long_host)

      if not host then
         return nil, err
      end

      obj.host = host
      obj.port = port

      obj.request_uri = obj.path .. "api/" .. obj.project_id .. "/store/"
      obj.server = obj.protocol .. "://" .. obj.long_host .. obj.request_uri

      return obj
   end

   return nil, "failed to parse DSN string"
end
_M._parse_dsn = _parse_dsn

--- Create a new Sentry client. Three parameters:
-- @param self raven client
-- @param dsn  The DSN of the Sentry instance with this format:
--             <pre>{PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{\HOST}/{PATH}{PROJECT_ID}</pre>
--             <pre>http://pub:secret@127.0.0.1:8080/sentry/proj-id</pre>
-- @param conf client configuration. Conf should be a hash table. Possible keys are:
--    <ul>
--    <li><span class="parameter">tags</span> extra tags to include on all reported errors</li>
--    <li><span class="parameter">logger</span></li>
--    <li><span class="parameter">verify_ssl</span> boolean of whether to perform SSL certificate verification</li>
--    <li><span class="parameter">cafile</span> path to CA certificate bundle file.
--        Required only when using luasec, ngx version uses the <tt>lua_ssl_trusted_certificate</tt> directive for this.</li>
--    </ul>
--             For example:
--             <pre>{ tags = { foo = "bar", abc = "def" }, logger = "myLogger", verify_ssl = false }</pre>
-- @return     a new raven instance
-- @usage
-- local raven = require "raven"
-- local rvn = raven:new(dsn, { tags = { foo = "bar", abc = "def" },
--     logger = "myLogger" })
function _M.new(self, dsn, conf)
   if not dsn then
      return nil, "empty dsn"
   end

   local obj = {}

   local ok, err = _parse_dsn(dsn, obj)
   if not ok then
      return nil, err
   end

   obj.client_id = "raven-lua/" .. version
   -- default level "error"
   obj.level = "error"
   obj.verify_ssl = true

   if conf then
      if conf.tags then
         obj.tags = conf.tags
      end

      if conf.logger then
         obj.logger = conf.logger
      end

      if conf.verify_ssl == false then
         obj.verify_ssl = false
      end


      obj.cafile = conf.cafile
   end

   return setmetatable(obj, mt)
end

--- Send an exception to Sentry.
-- see <a href="http://sentry.readthedocs.org/en/latest/developer/interfaces/index.html#sentry.interfaces.Exception">reference</a>.
--
-- @param self       raven client
-- @param exception  a hash table describing an exception. For example:
-- <pre>{{
--     ["type"] = "SyntaxError",
--     ["value"] = "Wattttt!",
--     ["module"] = "__builtins__",
--     stacktrace = {
--         frames = {
--             { filename = "/real/file/name", func = "myfunc", lineno" = 3 },
--             { filename = "/real/file/name", func = "myfunc1", lineno" = 10 },
--         }
--     }
-- }}</pre>
--
-- @param conf       capture configuration. Conf should be a hash table.
--                   Possible keys are: "tags", "trace_level". "tags" will be
--                   send to Sentry together with "tags" in client
--                   configuration. "trace_level" is used for geting stack
--                   backtracing. You shouldn't pass this argument unless you
--                   know what you are doing.
-- @return           On success, return event id. If not success, return nil and
--                   an error string.
-- @usage
-- local raven = require "raven"
-- local rvn = raven:new(dsn, { tags = { foo = "bar", abc = "def" },
--     logger = "myLogger" })
-- local id, err = rvn:captureException(exception,
--     { tags = { foo = "bar", abc = "def" }})
function _M.captureException(self, exception, conf)
   local trace_level
   if not conf then
      conf = { trace_level = 2 }
   elseif not conf.trace_level then
      conf.trace_level = 2
   else
      conf.trace_level = conf.trace_level + 1
   end

   trace_level = conf.trace_level

   clear_tab(_json)
   exception[1].stacktrace = backtrace(trace_level)
   _json.exception = exception
   _json.message = exception[1].value

   _json.culprit = self.get_culprit(conf.trace_level)


   -- because whether tail call will or will not appear in the stack back trace
   -- is different between PUC-lua or LuaJIT, so just avoid tail call
   local id, err = self:send_report(_json, conf)
   return id, err
end

--- Send a message to Sentry.
--
-- @param self       raven client
-- @param message    arbitrary message (most likely an error string)
-- @param conf       capture configuration. Conf should be a hash table.
--                   Possiable keys are: "tags", "trace_level". "tags" will be
--                   send to Sentry together with "tags" in client
--                   configuration. "trace_level" is used for geting stack
--                   backtracing. You shouldn't pass this argument unless you
--                   know what you are doing.
-- @return           On success, return event id. If not success, return nil and
--                   error string.
-- @usage
-- local raven = require "raven"
-- local rvn = raven:new(dsn, { tags = { foo = "bar", abc = "def" },
--     logger = "myLogger" })
-- local id, err = rvn:captureMessage("Sample message",
--     { tags = { foo = "bar", abc = "def" }})
function _M.captureMessage(self, message, conf)
   if not conf then
      conf = { trace_level = 2 }
   elseif not conf.trace_level then
      conf.trace_level = 2
   else
      conf.trace_level = conf.trace_level + 1
   end

   clear_tab(_json)
   _json.message = message

   _json.culprit = self.get_culprit(conf.trace_level)

   local id, err = self:send_report(_json, conf)
   return id, err
end

-- send_report: send report for the captured error.
--
-- Parameters:
--   json: json table to be sent. Don't need to fill event_id, culprit,
--   timestamp and level, send_report will fill these fields for you.
function _M.send_report(self, json, conf)
   local event_id = uuid4()

   -- TODO: Why is this line commented out?
   --json.project   = self.project_id,

   if not json then
      json = self.json
      if not json then
         return
      end
   end

   json.event_id  = event_id
   json.timestamp = iso8601()
   json.level     = self.level
   json.tags      = self.tags
   json.platform  = "lua"
   json.logger    = "root"

   if conf then
      if conf.tags then
         if not json.tags then
            json.tags = conf.tags
         else
            for k,v in pairs(conf.tags) do json.tags[k] = v end
         end
      end

      if conf.level then
         json.level = conf.level
      end
   end

   json.server_name = _get_server_name()

   local json_str = json_encode(json)
   local ok, err
   if self.protocol == "https" then
      ok, err = self:http_send(json_str, true)
   elseif self.protocol == "http" then
      ok, err = self:http_send(json_str, false)
   else
      error("protocol not implemented yet: " .. self.protocol)
   end

   if not ok then
      errlog("Failed to send to Sentry: ", err, " ",  json_str)
      return nil, err
   end
   return json.event_id
end

-- get culprit using given level
function _M.get_culprit(level)
   local culprit

   level = level + 1
   local info = debug_getinfo(level, "Snl")
   if info.name then
      culprit = info.name
   else
      culprit = info.short_src .. ":" .. info.linedefined
   end
   return culprit
end

-- catcher: used to catch an error from xpcall.
function _M.catcher(self, err)
   if debug then
       log("catch: ", err)
   end

   clear_tab(_exception[1])
   _exception[1].value = err
   _exception[1].stacktrace = backtrace(catcher_trace_level)

   clear_tab(_json)
   _json.exception = _exception
   _json.message = _exception[1].value

   _json.culprit = self.get_culprit(catcher_trace_level)

   return _json
end

--- Call function f with parameters ... wrapped in a xpcall and
-- send any exception to Sentry. Returns a boolean indicating whether
-- the function execution worked and an error if not
-- @param self  raven client
-- @param f     function to be called
-- @param ...   function "f" 's arguments
-- @return      the same with xpcall
-- @usage
-- function func(a, b, c)
--     return a * b + c
-- end
-- return rvn:call(func, a, b, c)
function _M.call(self, f, ...)
   -- When used with ngx_lua, connecting a tcp socket in xpcall error handler
   -- will cause a "yield across C-call boundary" error. To avoid this, we
   -- move all the network operations outside of the xpcall error handler.
   local json_exception
   local res = { xpcall(f,
                 function (err)
                     local ok
                     ok, json_exception = pcall(self.catcher, self, err)
                     if not ok then
                         -- when failed, json_exception is error message
                         errlog(json_exception)
                     end
                     return err
                 end,
                ...) }
   if json_exception then
       self:send_report(json_exception)
   end

   return unpack(res)
end

function _M.gen_capture_err(self)
   return function (err)
      local ok, json_exception = pcall(self.catcher, self, err)
      if not ok then
         -- when failed, json_exception is error message
         errlog(json_exception)
         self.json = nil
      else
         self.json = json_exception
      end
      return err
   end
end

-- HTTP request template
local xsentryauth_http = "POST %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nUser-Agent: %s\r\nX-Sentry-Auth: Sentry sentry_version=6, sentry_client=%s, sentry_timestamp=%s, sentry_key=%s, sentry_secret=%s\r\n\r\n%s"

-- http_send_core: do the actual network send. Expects an already
-- connected socket.
function _M.http_send_core(self, json_str)
   local req = string_format(xsentryauth_http,
                                self.request_uri,
                                self.long_host,
                                #json_str,
                                self.client_id,
                                self.client_id,
                                iso8601(),
                                self.public_key,
                                self.secret_key,
                                json_str)
   local bytes, err = self.sock:send(req)
   if not bytes then
      return nil, err
   end

   local res, err = self.sock:receive("*a")
   if not res then
      return nil, err
   end

   local s1, s2, status = string_find(res, "HTTP/%d%.%d (%d%d%d) %w+")
   if status ~= "200" then
      return nil, "Server response status not 200:" .. (status or "nil")
   end

   local s1, s2 = string_find(res, "\r\n\r\n")
   if not s1 and s2 then
      return ""
   end
   return string_sub(res, s2 + 1)
end

-- lua_wrap_tls: Enables TLS for luasocket. Requires luasec.
function _M.lua_wrap_tls(self, sock)
   if not ssl then
      error("no ssl library found, please install luasec")
   end

   local ok, err

   sock, err = ssl.wrap(sock, {
      mode = "client",
      protocol = "tlsv1_2",
      verify = self.verify_ssl and "peer" or "none",
      cafile = self.verify_ssl and self.cafile or nil,
      options = "all",
   })
   if not sock then
      return nil, err
   end

   ok, err = sock:dohandshake()
   if not ok then
      return nil, err
   end

   return sock
end

-- ngx_wrap_tls: Enables TLS for ngx.socket
function _M.ngx_wrap_tls(self, sock)
   local session, err = sock:sslhandshake(false, self.host, self.verify_ssl)
   if not session then
      return nil, err
   end
   return sock
end

-- wrap_tls: Wraps a connected socket with TLS
if ngx then
   _M.wrap_tls = _M.ngx_wrap_tls
else
   _M.wrap_tls = _M.lua_wrap_tls
end

-- http_send: actually sends the structured data to the Sentry server using
-- HTTP or HTTPS
function _M.http_send(self, json_str, secure)
   local ok, err
   local sock
   local port = self.port

   sock, err = socket.tcp()
   if not sock then
      return nil, err
   end

   -- Rely on default port values for http and https
   if not port then
      port = secure and 443 or 80
   end

   ok, err = sock:connect(self.host, port)
   if not ok then
      return nil, err
   end

   if secure then
      -- Sprinkle on some TLS juice
      local tlssock, err = self:wrap_tls(sock)
      if not tlssock then
         -- Need to close the tcp connection yet before bailing
         sock:close()
         return nil, err
      end
      sock = tlssock
   end

   self.sock = sock

   ok, err = self:http_send_core(json_str)

   sock:close()
   return ok, err
end

-- test client’s configuration from CLI
local function raven_test(dsn)
   local rvn, err = _M.new(_M, dsn, { tags = { source = "CLI test DSN" }})

   if not rvn then
      print(err)
   end

   print(string_format("Using DSN configuration:\n  %s\n", dsn))
   print(string_format([[Client configuration:
  Servers        : ['%s']
  project        : %s
  public_key     : %s
  secret_key     : %s
]], rvn.server, rvn.project_id, rvn.public_key, rvn.secret_key))
   print("Send a message...")
   local msg = "Hello from raven-lua!"
   local id, err = rvn:captureMessage(msg)

   if id then
      print("success!")
      print("Event id was '" .. id .. "'")
   else
      print("failed to send message '" .. msg .. "'\n" .. tostring(err))
   end

   print("Send an exception...")
   local exception = {{
     ["type"] = "SyntaxError",
     ["value"] = "Wattttt!",
     ["module"] = "__builtins__"
   }}
   local id, err = rvn:captureException(exception)

   if id then
      print("success!")
      print("Event id was '" .. id .. "'")
   else
      print("failed to send message '" .. msg .. "'\n" .. err)
   end
   print("All done.")
end

if arg and arg[1] and arg[1] == "test" then
   local dsn = arg[2]
   raven_test(dsn)
end

return _M
