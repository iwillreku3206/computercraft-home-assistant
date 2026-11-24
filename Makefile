PYTHON ?= python3
LUAC ?= luac
TARGETS ?=
UPDATE_URL ?=

BUILD_ARGS := $(if $(UPDATE_URL),--update-url "$(UPDATE_URL)")
LUA_SOURCES := $(wildcard shared/*.lua main/*.lua switch/*.lua dimmer/*.lua group/*.lua)

.DEFAULT_GOAL := all
.PHONY: all build check syntax clean help

all: build check

build:
	$(PYTHON) installers/build.py $(BUILD_ARGS) $(TARGETS)

check:
	@$(PYTHON) installers/build.py --check $(BUILD_ARGS) $(TARGETS)
	@$(PYTHON) -c 'compile(open("installers/build.py", encoding="utf-8").read(), "installers/build.py", "exec")'
	@for f in $(LUA_SOURCES) dist/install-*.lua; do \
		[ -f "$$f" ] || continue; \
		$(LUAC) -p "$$f" || exit 1; \
	done
	@echo "check: ok"

syntax:
	@$(PYTHON) -c 'compile(open("installers/build.py", encoding="utf-8").read(), "installers/build.py", "exec")'
	@for f in $(LUA_SOURCES) dist/install-*.lua; do \
		[ -f "$$f" ] || continue; \
		$(LUAC) -p "$$f" || exit 1; \
	done
	@echo "syntax: ok"

clean:
	rm -f dist/install-*.lua
	rm -rf installers/__pycache__

help:
	@echo "make build         regenerate dist/install-*.lua (TARGETS=client|switch|dimmer|all)"
	@echo "                   optional UPDATE_URL=<manifest-url> bakes the updater URL"
	@echo "make check         verify generated installers are current and syntax-check everything"
	@echo "make syntax        syntax-check build.py, Lua sources and generated installers"
	@echo "make clean         remove generated installers and Python caches"
