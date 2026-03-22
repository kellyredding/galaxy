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
	crystal build -o $(BUILDDIR)/galaxy-artifacts src/galaxy_artifacts.cr

# Release
build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy-artifacts src/galaxy_artifacts.cr

install: check build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-artifacts $(BINDIR)/galaxy-artifacts
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-artifacts $(LOCAL_BINDIR)/galaxy-artifacts
	@# Install skill
	$(BINDIR)/galaxy-artifacts install

clean:
	rm -rf $(BUILDDIR) lib .shards releases
