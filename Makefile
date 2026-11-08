# update-flatpak-cli -- build rules
#
#   make            build a static release binary into bin/
#   make dynamic    build a dynamically linked release binary instead
#   make debug      build with runtime checks and stack traces enabled
#   make test       run the unit tests and the end-to-end tests
#   make install    install the binary into ~/.local/bin
#   make clean      remove build artefacts
#
# Requires Nim >= 2.0 (https://nim-lang.org/install.html). No third-party
# packages are needed: everything comes from Nim's standard library.

BIN       := bin/update-flatpak-cli
MAIN      := src/update_flatpak_cli.nim
SOURCES   := $(wildcard src/*.nim) $(wildcard src/fpcli/*.nim)
NIM       ?= nim
NIMFLAGS  ?= --hints:off
RELEASE   := -d:release --opt:speed
STATIC    ?= 1

ifeq ($(STATIC),1)
LINKFLAGS := --passC:-static --passL:-static
else
LINKFLAGS :=
endif

PREFIX    ?= $(HOME)/.local
TESTBIN   := /tmp/update-flatpak-cli-testbin

.PHONY: all release dynamic debug test unit integration install uninstall clean check fmt help

all: release

help:
	@sed -n '2,14p' Makefile | sed 's/^# \{0,1\}//'

# Binaries are built to a temporary path and moved into place only on success,
# so an interrupted build never leaves a half-written binary in bin/.
release:
	@mkdir -p bin
	$(NIM) c $(NIMFLAGS) $(RELEASE) $(LINKFLAGS) -o:$(BIN).new $(MAIN)
	@mv -f $(BIN).new $(BIN)
	@echo "built $(BIN) ($$(du -h $(BIN) | cut -f1), $$(file -b $(BIN) | cut -d, -f1-2))"

dynamic:
	@mkdir -p bin
	$(NIM) c $(NIMFLAGS) $(RELEASE) -o:$(BIN).new $(MAIN)
	@mv -f $(BIN).new $(BIN)
	@echo "built $(BIN) (dynamic)"

debug:
	@mkdir -p bin
	$(NIM) c $(NIMFLAGS) --debugger:native --stackTrace:on --lineTrace:on \
		-o:$(BIN).new $(MAIN)
	@mv -f $(BIN).new $(BIN)
	@echo "built $(BIN) (debug)"

check:
	$(NIM) check $(NIMFLAGS) $(MAIN)

unit:
	@mkdir -p /tmp
	$(NIM) c -r $(NIMFLAGS) --path:src -o:$(TESTBIN)-unit tests/test_units.nim

integration: release
	tests/integration.sh $(BIN)

test: unit integration

install: release
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(notdir $(BIN))
	@echo "installed $(DESTDIR)$(PREFIX)/bin/$(notdir $(BIN))"
	@echo
	@echo "Now run it once to generate launchers, and make sure"
	@echo "$(HOME)/.local/bin/flatpak is at the end of your PATH."

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(notdir $(BIN))

clean:
	rm -rf bin/update-flatpak-cli bin/update-flatpak-cli.new nimcache
	rm -f $(TESTBIN)-unit
