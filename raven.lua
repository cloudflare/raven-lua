-- raven.lua: a Lua Raven client used to send errors to Sentry
-- Designed to run inside Nginx Lua. The main interface is then call()
-- function (which calls a function with arguments and traps
-- errors). The send() function can also be used to send a message to
-- Sentry.
--
-- Copyright (c) 2013, CloudFlare, Inc.

local debug_getinfo = debug.getinfo

local json = require("cjson")
local json_encode = json.encode

local math_random = math.random

local ngx = ngx

local os_date = os.date
local os_time = os.time

local setmetatable = setmetatable

local string_format = string.format
local string_match = string.match

local tostring = tostring

local xpcall = xpcall

module(...)

local mt = { __index = _M }

-- new: creates a new Sentry client. One parameter:
--
-- dsn:    The DSN of the Sentry instance with this format:
--         {PROTOCOL}://{PUBLIC_KEY}:{SECRET_KEY}@{HOST}/{PATH}{PROJECT_ID}
--         This implementation only supports UDP
function new(self, dsn)
   return setmetatable({dsn=dsn,
                        sock=nil,
                        project_id=nil,
                        host=nil,
                        port=nil,
                        public_key=nil,
                        secret_key=nil,
                        client_id="Lua Sentry Client/0.1",
                        levels={'fatal','error','warning','info','debug'}}, mt)
end

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

-- catcher: used to catch an error from xpcall and send the
-- information to Sentry
function catcher(self, err)
   local culprit = ''
   local stack = ''
   local level = 2
   while true do
      local info = debug_getinfo(level, "Snl")
      if not info then break end
      local f
      if info.what == "C" then
         f = "[C] " .. tostring(info.name)
      else
         f = string_format("%s (%s:%d)", tostring(info.name), info.short_src, info.currentline)
      end
      if level == 2 then culprit = f end
      stack = stack .. f .. "\n"
      level = level + 1
   end
   err = err .. "\n" .. stack
   capture(self, self.levels[2], err, culprit, nil)
end

-- call: call function f with parameters ... wrapped in a xpcall and
-- send any exception to Sentry. Returns a boolean indicating whether
-- the function execution worked and an error if not
function call(self, f, ...)
   return xpcall(f,
                 function (err) self:catcher(err) end,
                ...)
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
function capture(self, level, message, culprit, tags)
   if not self.project_id then
      self.public_key, self.secret_key, self.host, self.port, self.project_id =
         string_match(self.dsn, "^udp://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$")
   end

   if self.project_id then
      local event_id = uuid4()

      send(self, {
              project   = self.project_id,
              event_id  = event_id,
              timestamp = iso8601(),
              culprit   = culprit,
              level     = level,
              message   = message,
              tags      = tags
      })
      
      return event_id
   end
   
   return nil
end

local xsentryauth="Sentry sentry_version=2.0,sentry_client=%s,sentry_timestamp=%s,sentry_key=%s,sentry_secret=%s\n\n%s\n"

-- send: actually sends the structured data to the Sentry server
function send(self, t)
   local t_json = json_encode(t)

   if not self.sock then
      local sock = ngx.socket.udp()

      if sock then
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

setmetatable(_M, class_mt)
