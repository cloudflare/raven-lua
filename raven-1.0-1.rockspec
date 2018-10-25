package = "raven"
 version = "1.0-1"
 source = {
    url = "git://github.com/inspectorioinc/raven-lua.git",
    tag = "1.0-1",
 }
 description = {
    summary = "Lua (openresty) client for Sentry.",
    detailed = [[
       Send sentry events/alerts from open resty app.
    ]],
    homepage = "https://github.com/inspectorioinc/raven-lua",
    license = "MIT/X11"
 }
 dependencies = {
    "lua >= 5.1",
 }
 build = {
    type = "builtin",
    modules =  {      
    ["raven.senders.luasocket"] = "raven/senders/luasocket.lua",
    ["raven.senders.ngx"] = "raven/senders/ngx.lua",
    ["raven.senders.reference"] = "raven/senders/reference.lua",
    ["raven.senders.test"] = "raven/senders/test.lua",
    ["raven.init"] = "raven/init.lua",
    ["raven.util"] = "raven/util.lua",
    }
 }
