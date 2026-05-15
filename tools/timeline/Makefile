.PHONY: build install clean test lint format check dev deps

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
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# check builds dev binary first (integration specs need it)
check: dev test lint

dev: deps format
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy-timeline src/galaxy_timeline.cr

# Release
build: deps
	@mkdir -p $(BUILDDIR)
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy-timeline src/galaxy_timeline.cr

install: check build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-timeline $(BINDIR)/galaxy-timeline
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-timeline $(LOCAL_BINDIR)/galaxy-timeline

clean:
	rm -rf $(BUILDDIR) lib .shards releases
