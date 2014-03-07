-- Copyright (c) 2013, CloudFlare, Inc.
-- @author JGC <jgc@cloudflare.com>
-- @author Jiale Zhi <vipcalio@gmail.com>
-- raven.lua: a Lua Raven client used to send errors to Sentry

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


local _json = {
     platform  = "lua",
}

local _M = {}

local mt = { __index = _M }

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

local function get_server_name()
   return ngx and ngx.var.server_name or "undefined"
end

--- Parse long host ("127.0.0.1:2222") to host ("127.0.0.1") and port (2222)
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
   return setmetatable(obj, mt)
   --[[
   return setmetatable({dsn=dsn,
                        sock=nil,
                        project_id=nil,
                        host=nil,
                        port=nil,
                        public_key=nil,
                        secret_key=nil,
                        client_id="Lua Sentry Client/0.4",
                        levels={'fatal','error','warning','info','debug'}}, mt)
                        ]]
end

function _M.captureException(self, exception, conf)

end

function _M.captureMessage(self, message, conf)
   _json.message = message
   self:capture_core(_json)
end

function _M.capture_core(self, json)
   local culprit, stack = self.get_debug_info(4)

   --json.project   = self.project_id,
   json.event_id  = uuid4()
   json.culprit   = culprit
   json.timestamp = iso8601()
   json.level     = self.level
   -- TODO
   --tags      = tags,
   json.server_name = get_server_name()

   if self.protocol == "udp" then
      self:udp_send(json)
   else
      error("protocol not implemented yet: " .. self.protocol)
   end
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
   --[[
   while true do
      local info = debug_getinfo(level, "Snl")
      if not info then break end
      local f
      if info.what == "C" then
         f = "[C] " .. tostring(info.name)
      else
         f = string_format("%s (%s:%d)", tostring(info.name), info.short_src,
               info.currentline)
      end
      if level == 2 then culprit = f end
      stack = stack .. f .. "\n"
      level = level + 1
   end
   ]]
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
local xsentryauth="Sentry sentry_version=2.0,sentry_client=%s,"
      .. "sentry_timestamp=%s,sentry_key=%s,sentry_secret=%s\n\n%s\n"

function _M.http_send(self, t)
end

-- send: actually sends the structured data to the Sentry server
function _M.udp_send(self, t)
   local t_json = json_encode(t)

   if not self.sock then
      local sock = socket.udp()

      if sock then

         -- TODO: Don't ignore the error on the setpeername here

         sock:setpeername(self.host, self.port)
         self.sock = sock
      end
   end

   if self.sock then
      self.sock:send(string_format(xsentryauth,
                                   self.client_id,
                                   iso8601(),
                                   self.public_key,
                                   self.secret_key,
                                   t_json))
   end
end

local class_mt = {
   __newindex = function (table, key, val)
      error('attempt to write to undeclared variable "' .. tostring(key) .. '"')
   end
}

--setmetatable(_M, class_mt)
return _M
