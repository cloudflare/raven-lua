package = "raven-lua"
version = "scm-1"
source = {
   url = "https://github.com/cloudflare/raven-lua.git"
}
description = {
   detailed = [[
A small Lua interface to [Sentry](https://sentry.readthedocs.org/) that also
has a helpful wrapper function `call()` that takes any arbitrary Lua function
(with arguments) and executes it, traps any errors and reports it automatically
to Sentry.]],
   homepage = "https://github.com/cloudflare/raven-lua",
   license = "BSD 3-clause"
}
dependencies = {
  "lua >= 5.1",
  "lua-cjson",
}
build = {
   type = "builtin",
   modules = {
      raven = "raven/init.lua",
      ["raven.senders.luasocket"] = "raven/senders/luasocket.lua",
      ["raven.senders.ngx"] = "raven/senders/ngx.lua",
      ["raven.senders.reference"] = "raven/senders/reference.lua",
      ["raven.senders.test"] = "raven/senders/test.lua",
      ["raven.util"] = "raven/util.lua",
   },
   copy_directories = {
   }
}
