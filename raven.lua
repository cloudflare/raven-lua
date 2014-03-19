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

local json = require("cjson")

local ngx = ngx
local arg = arg
local setmetatable = setmetatable
local tostring = tostring
local xpcall = xpcall

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

local socket
local catcher_trace_level
if not ngx then
   local ok, luasocket = pcall(require, "socket")
   if not ok then
      error("No socket library found, you need ngx.socket or luasocket.")
   end
   socket = luasocket
   catcher_trace_level = 3
else
   socket = ngx.socket
   catcher_trace_level = 4
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

-- backup logging when cannot send data to sentry
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

math.randomseed(os.time())

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
function _M._parse_host_port(protocol, host)
   local i = string_find(host, ":")
   if not i then
      -- TODO
      return host, 80
   end

   local port_str = string_sub(host, i + 1)
   local port = tonumber(port_str)
   if not port then
      return nil, nil, "illegal port: " .. port_str
   end

   return string_sub(host, 1, i - 1), port
end

-- _parse_dsn: gets protocol, public_key, secret_key, host, port, path and
-- project from DSN
function _M._parse_dsn(dsn, obj)
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

      local host, port, err = _M._parse_host_port(obj.protocol, obj.long_host)

      if not host or not port then
         return nil, err
      end

      obj.host = host
      obj.port = port

      obj.request_uri = obj.path .. "api/" .. obj.project_id .. "/store/"
      obj.server = obj.protocol .. "://" .. obj.long_host .. obj.request_uri

      return obj
   end   

   return nil
end

--- Create a new Sentry client. Two parameters:
-- @param self raven client
-- @param dsn  The DSN of the Sentry instance with this format:
--             <pre>{PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}</pre>
--             Both HTTP protocol and UDP protocol are supported. For example:
--             <pre>http://pub:secret@127.0.0.1:8080/sentry/proj-id</pre>
--             <pre>udp://pub:secret@127.0.0.1:8080/sentry/proj-id</pre>
-- @param conf client configuration. Conf should be a hash table. Possiable
--             keys are: "tags", "logger". For example:
--             <pre>{ tags = { foo = "bar", abc = "def" }, logger = "myLogger" }</pre>
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

   if not _M._parse_dsn(dsn, obj) then
      return nil, "Bad DSN"
   end

   obj.client_id = "raven-lua/0.4"
   -- default level "error"
   obj.level = "error"

   if conf then
      if conf.tags then
         obj.tags = { conf.tags }
      end

      if conf.logger then
         obj.logger = conf.logger
      end
   end

   return setmetatable(obj, mt)
end

--- Send an exception to sentry.
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
--                   Possiable keys are: "tags", "trace_level". "tags" will be
--                   send to sentry together with "tags" in client
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

   -- because whether tail call will or will not appear in the stack back trace
   -- is different between PUC-lua or LuaJIT, so just avoid tail call
   local id, err = self:capture_core(_json, conf)
   return id, err
end

--- Send a message to sentry.
--
-- @param self       raven client
-- @param message    arbitrary message (most likely an error string)
-- @param conf       capture configuration. Conf should be a hash table.
--                   Possiable keys are: "tags", "trace_level". "tags" will be
--                   send to sentry together with "tags" in client
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

   local id, err = self:capture_core(_json, conf)
   return id, err
end

-- capture_core: core capture function.
--
-- Parameters:
--   json: json table to be sent. Don't need to fill event_id, culprit,
--   timestamp and level, capture_core will fill these fields for you.
function _M.capture_core(self, json, conf)
   conf.trace_level = conf.trace_level + 1

   local culprit = self.get_culprit(conf.trace_level)

   local event_id = uuid4()
   --json.project   = self.project_id,
   json.event_id  = event_id
   json.culprit   = culprit
   json.timestamp = iso8601()
   json.level     = self.level
   json.tags      = self.tags
   json.platform  = "lua"
   json.logger    = "root"

   if conf then
      if conf.tags then
         if not json.tags then
            json.tags = { conf.tags }
         else
            json.tags[#json.tags + 1] = conf.tags
         end
      end

      if conf.level then
         json.level = conf.level
      end
   end

   json.server_name = _get_server_name()

   local json_str = json_encode(json)
   local ok, err
   if self.protocol == "udp" then
      ok, err = self:udp_send(json_str)
   elseif self.protocol == "http" then
      ok, err = self:http_send(json_str)
   else
      error("protocol not implemented yet: " .. self.protocol)
   end

   if not ok then
      errlog("Failed to send to sentry: ",err, " ",  json_str)
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

-- catcher: used to catch an error from xpcall and send the
-- information to Sentry
function _M.catcher(self, err)
   local culprit
   local stack

   clear_tab(_exception[1])
   _exception[1].value = err

   self:captureException(_exception, { trace_level = catcher_trace_level })
end

--- Call function f with parameters ... wrapped in a xpcall and
-- send any exception to Sentry. Returns a boolean indicating whether
-- the function execution worked and an error if not
-- @param self  raven client
-- @param f     function to be called
-- @param ...   function "f" 's arguments
-- @return      "f" 's return value(s)
-- @usage
-- function func(a, b, c)
--     return a * b + c
-- end
-- return rvn:call(func, a, b, c)
function _M.call(self, f, ...)
   return xpcall(f,
                 function (err) self:catcher(err) end,
                ...)
end

-- UDP request template
local xsentryauth_udp="Sentry sentry_version=2.0,sentry_client=%s,"
      .. "sentry_timestamp=%s,sentry_key=%s,sentry_secret=%s\n\n%s\n"

-- HTTP request template
local xsentryauth_http = "POST %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nUser-Agent: %s\r\nX-Sentry-Auth: Sentry sentry_version=5, sentry_client=%s, sentry_timestamp=%s, sentry_key=%s, sentry_secret=%s\r\n\r\n%s"

-- udp_send: actually sends the structured data to the Sentry server using
-- UDP protocol
function _M.udp_send(self, json_str)
   local ok, err

   if not self.sock then
      local sock = socket.udp()

      if sock then
         ok, err = sock:setpeername(self.host, self.port)
         if not ok then
            return nil, err
         end
         self.sock = sock
      end
   end

   local bytes

   if self.sock then
      local content = string_format(xsentryauth_udp,
                                   self.client_id,
                                   iso8601(),
                                   self.public_key,
                                   self.secret_key,
                                   json_str)
      bytes, err = self.sock:send(content)
   end
   return bytes, err
end

-- http_send_core: do the actual network send work. Expect an already
-- connected socket
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
      return nil, "Server response status not 200:" .. status
   end

   local s1, s2 = string_find(res, "\r\n\r\n")
   if not s1 and s2 then
      return ""
   end
   return string_sub(res, s2 + 1)
end

-- http_send: actually sends the structured data to the Sentry server using
-- HTTP protocol
function _M.http_send(self, json_str)
   local ok, err
   local sock

   sock, err = socket.tcp()
   if not sock then
      return nil, err
   end
   self.sock = sock

   ok, err = sock:connect(self.host, self.port)
   if not ok then
      return nil, err
   end

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
