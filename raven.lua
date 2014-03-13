-- Copyright (c) 2013, CloudFlare, Inc.
-- @author JGC <jgc@cloudflare.com>
-- @author Jiale Zhi <vipcalio@gmail.com>
-- raven.lua: a Lua Raven client used to send errors to Sentry
--
-- According to client development guide
--
--    The following items are expected of production-ready clients:
--
--    √ DSN configuration
--    √ Graceful failures (e.g. Sentry server unreachable)
--    Scrubbing w/ processors
--    √ Tag support
--

local json = require("cjson")

local ngx = ngx
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

local socket
if not ngx then
   local ok, luasocket = pcall(require, "socket")
   if not ok then
      error("No socket library found, you need ngx.socket or luasocket.")
   end
   socket = luasocket
end

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local function log(...)
   if not ngx then
      print(...)
   else
      ngx.log(ngx.NOTICE, ...)
   end
end

local _json = {
     platform  = "lua",
     logger    = "root",
}

local _M = {}

local mt = {
   __index = _M,
}

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
   else
      return nil
   end
end

-- new: creates a new Sentry client. Two parameters:
--
-- dsn:    The DSN of the Sentry instance with this format:
--         {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}
--         This implementation only supports UDP
function _M.new(self, dsn, conf)
   if not dsn then
      return nil, "empty dsn"
   end

   local obj = {}

   if not _M._parse_dsn(dsn, obj) then
      return nil, "Bad DSN"
   end

   obj.client_id = "Lua Sentry Client/0.4"
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

   -- log("new raven client, DSN: " .. dsn)
   return setmetatable(obj, mt)
end

function _M.captureException(self, exception, conf)

end

-- captureMessage: capture an message and send it to sentry.
--
-- Parameters:
--   messsage: arbitrary message (most likely an error string)
--
function _M.captureMessage(self, message, conf)
   _json.message = message
   return self:capture_core(_json, conf)
end

-- capture_core: core capture function.
--
-- Parameters:
--   json: json table to be sent. Don't need to fill event_id, culprit,
--   timestamp and level, capture_core will fill these fileds for you.
function _M.capture_core(self, json, conf)
   local culprit, stack = self.get_debug_info(4)

   local event_id = uuid4()
   --json.project   = self.project_id,
   json.event_id  = event_id
   json.culprit   = culprit
   json.timestamp = iso8601()
   json.level     = self.level
   json.tags      = self.tags

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
   -- TODO
   --tags      = tags,
   json.server_name = _get_server_name()

   if self.protocol == "udp" then
      self:udp_send(json)
   elseif self.protocol == "http" then
      local ok, err = self:http_send(json)
      if not ok then
         return nil, err
      end
   else
      error("protocol not implemented yet: " .. self.protocol)
   end

   return json.event_id
end

-- capture: capture an error that has occurred and send it to
-- sentry. Returns the ID of the report or nil if an error occurred.
--
-- Parameters:
--
--  level: a string representing a severity should be drawn from the
--         levels array above
--
--  message: arbitrary message (most likely an error string)
--
--  cuplrit: typically the name of the function call that caused the
--           event (or alternatively the name of the module)
--
--  tags: a table of tags to associate with the event being captured
--        (expected to be key: value pairs)
--
function _M.capture(self, level, message, exception, culprit, tags)

   if self.project_id then
      local event_id = uuid4()

      send(self, {
              project   = self.project_id,
              event_id  = event_id,
              timestamp = iso8601(),
              culprit   = culprit,
              level     = level,
              message   = message,
              tags      = tags,
              server_name = ngx.var.server_name,
              platform  = "lua",
--[[
              logger
              modules
              extra
]]
      })

      return event_id
   end

   return nil
end

-- level 2 is the function which calls get_debug_info
function _M.get_debug_info(level)
   local culprit = ''
   local stack = ''
   local level = level and level or 2
   --print(json.encode(debug_getinfo(2, "Snl")))
   local info = debug_getinfo(level, "Snl")
   if info.name then
      culprit = info.name
   else
      culprit = info.short_src .. ":" .. info.linedefined
   end
   stack = debug.traceback("", 2)
   return culprit, stack
end

-- catcher: used to catch an error from xpcall and send the
-- information to Sentry
function catcher(self, err)
   local culprit
   local stack
   culprit, stack = get_debug_info()
   err = err .. "\n" .. stack
   capture(self, self.levels[2], err, culprit, nil)
end

-- call: call function f with parameters ... wrapped in a pcall and
-- send any exception to Sentry. Returns a boolean indicating whether
-- the function execution worked and an error if not
function call(self, f, ...)
   return xpcall(f,
                 function (err) self:catcher(err) end,
                ...)
end

local xsentryauth_udp="Sentry sentry_version=2.0,sentry_client=%s,"
      .. "sentry_timestamp=%s,sentry_key=%s,sentry_secret=%s\n\n%s\n"

local xsentryauth_http = "POST %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %d\r\nUser-Agent: %s\r\nX-Sentry-Auth: Sentry sentry_version=5, sentry_client=%s, sentry_timestamp=%s, sentry_key=%s, sentry_secret=%s\r\n\r\n%s"

-- udp_send: actually sends the structured data to the Sentry server using
-- UDP protocol
function _M.udp_send(self, t)
   local t_json = json_encode(t)
   local ok, err

   if not self.sock then
      local sock = socket.udp()

      if sock then

         -- TODO: Don't ignore the error on the setpeername here

         ok, err = sock:setpeername(self.host, self.port)
         if not ok then
            return nil, err
         end
         self.sock = sock
      end
   end

   local bytes

   if self.sock then
      bytes, err = self.sock:send(string_format(xsentryauth_udp,
                                   self.client_id,
                                   iso8601(),
                                   self.public_key,
                                   self.secret_key,
                                   t_json))
   end
   return bytes, err
end

-- http_send: actually sends the structured data to the Sentry server using
-- HTTP protocol
function _M.http_send(self, t)
   local t_json = json_encode(t)
   local ok, err
   local sock

   if not self.sock then
      sock, err = socket.tcp()
      if not sock then
         return nil, err
      end
      self.sock = sock
   end

   ok, err = sock:connect(self.host, self.port)
   if not ok then
      return nil, err
   end

   local bytes

   local req = string_format(xsentryauth_http,
                                self.request_uri,
                                self.long_host,
                                #t_json,
                                self.client_id,
                                self.client_id,
                                iso8601(),
                                self.public_key,
                                self.secret_key,
                                t_json)
   --print(req)
   bytes, err = self.sock:send(req)
   if not bytes then
      return nil, err
   end

   local res, err = self.sock:receive("*a")
   if not res then
      return nil, err
   end

   local s1, s2, status = string_find(res, "HTTP/%d%.%d (%d%d%d) %w+")
   if status and status == "200" then
      return bytes
   end

   local s1, s2 = string_find(res, "\r\n\r\n")
   return nil, string_sub(res, s2 + 1)
end

local function test_dsn(dsn)
   local rvn, err = _M.new(_M, dsn)

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
   local msg = "Hello from lua-raven!"
   local id, err = rvn:captureMessage(msg)

   if id then
      print("success!")
      print("Event id was '" .. id .. "'")
   else
      print("failed to send message '" .. msg .. "'\n" .. err)
   end
end

if arg[1] and arg[1] == "test" then
   local dsn = arg[2]
   test_dsn(dsn)
end

return _M
