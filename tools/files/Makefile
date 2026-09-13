.PHONY: build install clean test lint format check dev deps

PREFIX ?= $(HOME)/.claude/galaxy
BINDIR ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin
BUILDDIR ?= build

# Dependencies
deps: lib/.shards-installed

lib/.shards-installed: shard.yml
	shards install
	@mkdir -p lib
	@touch lib/.shards-installed

# Development
test:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# check builds dev binary first (integration specs need it)
check: lint dev test

dev: deps
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy-files src/galaxy_files.cr

# Release
build: deps
	@mkdir -p $(BUILDDIR)
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy-files src/galaxy_files.cr

install: check build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-files $(BINDIR)/galaxy-files
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-files $(LOCAL_BINDIR)/galaxy-files
	@# Install skill
	$(BINDIR)/galaxy-files install

clean:
	rm -rf $(BUILDDIR) lib .shards releases
