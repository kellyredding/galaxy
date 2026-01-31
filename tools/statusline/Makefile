.PHONY: build install clean test lint format check dev

PREFIX ?= $(HOME)/.claude/galaxc
BINDIR ?= $(PREFIX)/bin
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
	crystal build -o $(BUILDDIR)/galaxc-statusline src/galaxc_statusline.cr

# Release
build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug -o $(BUILDDIR)/galaxc-statusline src/galaxc_statusline.cr

install: build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxc-statusline $(BINDIR)/galaxc-statusline

clean:
	rm -rf $(BUILDDIR) lib .shards releases
