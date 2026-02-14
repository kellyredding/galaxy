.PHONY: build install clean test test-eval test-all lint format check dev

PREFIX ?= $(HOME)/.claude/galaxy
BINDIR ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin
BUILDDIR ?= build

# Development
test: format
	crystal spec --tag '~eval'

test-eval:
	crystal spec --tag eval

test-all:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# check builds dev binary first (integration specs need it)
check: dev test lint

dev: format
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy-ledger src/galaxy_ledger.cr

# Release
build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy-ledger src/galaxy_ledger.cr

install: check test-eval build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-ledger $(BINDIR)/galaxy-ledger
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-ledger $(LOCAL_BINDIR)/galaxy-ledger

clean:
	rm -rf $(BUILDDIR) lib .shards releases
