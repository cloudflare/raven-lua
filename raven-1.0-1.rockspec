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
      raven = "raven"
    }
 }
