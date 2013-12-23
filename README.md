lua-raven
=========

A small Lua interface to [Sentry](http://sentry.readthedocs.org/) that
only supports the UDP interface, but has a helpful wrapper function
(call()) that calls an arbitrary Lua function (with arguments) and
traps any errors and reports it automatically to Sentry.
