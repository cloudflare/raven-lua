-- vim: st=4 sts=4 sw=4 et:
--- Network backend using [lua-resty-http](https://github.com/ledgetech/lua-resty-http).
--- Supports https, http, and keepalive for better performance.
--
-- @module raven.senders.lua-resty-http
-- @copyright 2014-2017 CloudFlare, Inc.
-- @license BSD 3-clause (see LICENSE file)

local util = require 'raven.util'
local http = require 'resty.http'

local tostring = tostring
local cjson_encode = cjson.encode
local pairs = pairs
local setmetatable = setmetatable
local table_concat = table.concat
local parse_dsn = util.parse_dsn
local generate_auth_header = util.generate_auth_header
local _VERSION = util._VERSION
local _M = {}

local mt = {}
mt.__index = mt

function mt:send(json_str)
    local httpc = http.new()
    local res, err = httpc:request_uri(self.server, {
        method = "POST",
        headers = {
            ['Content-Type'] = 'applicaion/json',
            ['User-Agent'] = "raven-lua-http/" .. _VERSION,
            ['X-Sentry-Auth'] = generate_auth_header(self),
            ["Content-Length"] = tostring(#json_str),
        },
        body = cjson_encode(json_str),
        keepalive = self.opts.keepalive,
        keepalive_timeout = self.opts.keepalive_timeout,
        keepalive_pool = self.opts.keepalive_pool
    })

    if not res then
        return nil, table_concat(res)
    end

    return true
end

--- Configuration table for the nginx sender.
-- @field dsn DSN string
-- @field verify_ssl Whether or not the SSL certificate is checked (boolean,
--  defaults to false)
-- @field cafile Path to a CA bundle (see the `cafile` parameter in the
--  [newcontext](https://github.com/brunoos/luasec/wiki/LuaSec-0.6#ssl_newcontext)
--  docs)
-- @table sender_conf

--- Create a new sender object for the given DSN
-- @param conf Configuration table, see @{sender_conf}
-- @return A sender object
function _M.new(conf)
    local obj, err = parse_dsn(conf.dsn)
    if not obj then
        return nil, err
    end

    obj.opts = {
        verify = conf.verify_ssl or false,
        keepalive = conf.keepalive or false,
        keepalive_timeout = conf.keepalive_timeout or 0,
        keepalive_pool = conf.keepalive_pool or 0
    }

    return setmetatable(obj, mt)
end

return _M

