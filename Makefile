# Simple Makefile for raven-lua that runs tests and generates docs
#
# Copyright (c) 2014-2017 CloudFlare, Inc.

all: test

.PHONY: lint
lint:
	luacheck .

.PHONY: test
test: lint
	tsc tests/*.lua
	sed -e "s|%PWD%|$$PWD|" tests/sentry.conf > tests/sentry.conf.out
	touch empty-file
	resty --http-include $$PWD/tests/sentry.conf.out -e 'require("luarocks.loader"); require("telescope.runner")(arg)' empty-file tests/resty/*.lua

.PHONY: doc
doc:
	ldoc .

