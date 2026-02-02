.PHONY: build install clean test lint format check dev

PREFIX ?= $(HOME)/.claude/galaxy
BINDIR ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin
BUILDDIR ?= build

# Development
test:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# check builds dev binary first (integration specs need it)
check: lint dev test

dev:
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy src/galaxy.cr

# Release
build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug -o $(BUILDDIR)/galaxy src/galaxy.cr

install: build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy $(BINDIR)/galaxy
	@# Symlink to local bin for PATH access
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy $(LOCAL_BINDIR)/galaxy

clean:
	rm -rf $(BUILDDIR) lib .shards releases
