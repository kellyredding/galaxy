.PHONY: build install clean test lint format check dev

PREFIX ?= $(HOME)/.claude/galaxy
BINDIR ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin
BUILDDIR ?= build

# Development
test: format
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# check builds dev binary first (integration specs need it)
check: dev test lint

dev: format
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy-snapshots src/galaxy_snapshots.cr

# Release
build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy-snapshots src/galaxy_snapshots.cr

install: check build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-snapshots $(BINDIR)/galaxy-snapshots
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-snapshots $(LOCAL_BINDIR)/galaxy-snapshots
	@# Install hooks + skills
	$(BINDIR)/galaxy-snapshots install

clean:
	rm -rf $(BUILDDIR) lib .shards releases
