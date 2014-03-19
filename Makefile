# Simple Makefile for raven-lua that runs tests and generates docs
#
# Copyright (c) 2014 CloudFlare, Inc.

LUNIT := $(shell which lunit)
ifeq ($(LUNIT),)
$(error lunit is required to run test suite)
endif

LDOC := $(shell which ldoc)

TESTS := $(wildcard tests/*.lua)

MODULES := raven.lua

.PHONY: test
test: $(TESTS) ; @lunit $(TESTS)

doc: $(MODULES) ; @ldoc -d docs $(MODULES)

print-%: ; @echo $*=$($*)
