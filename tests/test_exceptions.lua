
require "lunit"
local socket = require "socket"
local raven = require "raven"
local cjson = require "cjson"

local print = print
local error = error

module("test_exceptions", lunit.testcase)

local rvn
local port = 29999
local dsn_http = "http://pub:secret@127.0.0.1:" .. port .. "/sentry/proj-id"
local dsn_udp = "udp://pub:secret@127.0.0.1:" .. port .. "/sentry/proj-id"

function test_capture_message_connection_refused_http()
   local rvn = raven:new(dsn_http)
   local id, err = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")

   assert_nil(id)
   assert_equal("connection refused", err)
end

function test_capture_message_connection_refused_udp()
   local rvn = raven:new(dsn_udp)
   local id, err = rvn:captureMessage("Sentry is a realtime event logging and aggregation platform.")

   assert_not_nil(id)
end
