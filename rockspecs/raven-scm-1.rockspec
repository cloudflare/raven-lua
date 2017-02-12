package = "raven"
version = "scm-1"

source = {
    url = "git://github.com/cloudflare/raven-lua.git"
}

description = {
    summary = "A Lua interface to Sentry",
    detailed = [[
        Sentry is Software as a Service that lets you detect errors
        in your production software.
    ]],
    homepage = "https://github.com/cloudflare/raven-lua",
    license = "MIT/X11",
}

dependencies = {
    "lua >= 5.1",
    "luasocket",
    "lua-cjson"
}

build = {
    type = "none",
    install = { lua = {raven = "raven.lua"} },
    copy_directories = {},
}
