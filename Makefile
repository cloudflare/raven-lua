# Simple Makefile for raven-lua that runs tests
#
# Copyright (c) 2014 CloudFlare, Inc.

LUNIT := $(shell which lunit)
ifeq ($(LUNIT),)
$(error lunit is required to run test suite)
endif

TESTS := $(wildcard tests/*.lua)

.PHONY: test
test: $(TESTS) ; @lunit $(TESTS)

print-%: ; @echo $*=$($*)
