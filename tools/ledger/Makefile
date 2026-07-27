.PHONY: build install clean test test-eval test-all lint format check dev deps sandbox

PREFIX ?= $(HOME)/.claude/galaxy
BINDIR ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin
BUILDDIR ?= build

# Dependencies
deps: lib/.shards-installed

lib/.shards-installed: shard.yml
	shards install
	@touch lib/.shards-installed

# Development
test: format
	crystal spec --tag '~eval'

test-eval:
	crystal spec --tag eval

# End-to-end accrual checks against a throwaway database.
# Requires a current $(BUILDDIR)/galaxy-ledger — run `make dev` first.
sandbox:
	./script/sandbox/accrual-scenarios.sh
	./script/sandbox/resume-scenarios.sh

test-all:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# check builds dev binary first (integration specs need it)
check: dev test lint

dev: deps format
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy-ledger src/galaxy_ledger.cr

# Release
build: deps
	@mkdir -p $(BUILDDIR)
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy-ledger src/galaxy_ledger.cr

install: check test-eval build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-ledger $(BINDIR)/galaxy-ledger
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-ledger $(LOCAL_BINDIR)/galaxy-ledger
	@# Install hooks + skills
	$(BINDIR)/galaxy-ledger install

clean:
	rm -rf $(BUILDDIR) lib .shards releases
