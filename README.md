raven-lua
=========

[![Build Status](https://travis-ci.org/cloudflare/raven-lua.svg?branch=master)](https://travis-ci.org/cloudflare/raven-lua)

A small Lua interface to [Sentry](https://sentry.readthedocs.org/) that also
has a helpful wrapper function `call()` that takes any arbitrary Lua function
(with arguments) and executes it, traps any errors and reports it automatically
to Sentry.

Synopsis
========

```lua

    local raven = require "raven"

    -- http://pub:secret@127.0.0.1:8080/sentry/proj-id
    local rvn = raven:new("http://pub:secret@127.0.0.1:8080/sentry/proj-id", {
       tags = { foo = "bar" },
    })

    -- Send a message to sentry
    local id, err = rvn:captureMessage(
      "Sentry is a realtime event logging and aggregation platform.",
      { tags = { abc = "def" } } -- optional
    )
    if not id then
       print(err)
    end

    -- Send an exception to sentry
    local exception = {{
       ["type"]= "SyntaxError",
       ["value"]= "Wattttt!",
       ["module"]= "__builtins__"
    }}
    local id, err = rvn:captureException(
       exception,
       { tags = { abc = "def" } } -- optional
    )
    if not id then
       print(err)
    end

    -- Catch an exception and send it to sentry
    function bad_func(n)
       return not_defined_func(n)
    end

    -- variable 'ok' should be false, and an exception will be sent to sentry
    local ok = rvn:call(bad_func, 1)

```
Documents
=========

See docs/index.html for more details.

Prerequisites
=============
To run the tests:
```
    luarocks install lunit
    luarocks install lua-cjson
    luarocks install luaposix
    luarocks install luasocket
    luarocks install luasec

    lunit tests/*.lua
```

To generate the docs:
```
    luarocks install ldoc

    ldoc raven.lua -d docs -p raven-lua
```
