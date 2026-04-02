.PHONY: build install clean test lint format check dev

PREFIX ?= $(HOME)/.claude/galaxy
BINDIR ?= $(PREFIX)/bin
LOCAL_BINDIR ?= $(HOME)/.local/bin
BUILDDIR ?= build

test: format
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

check: dev test lint

dev: format
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/galaxy-agents \
	  src/galaxy_agents.cr

build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug \
	  -o $(BUILDDIR)/galaxy-agents src/galaxy_agents.cr

install: check build
	install -d $(BINDIR)
	install -m 755 $(BUILDDIR)/galaxy-agents \
	  $(BINDIR)/galaxy-agents
	@mkdir -p $(LOCAL_BINDIR)
	@ln -sf $(BINDIR)/galaxy-agents \
	  $(LOCAL_BINDIR)/galaxy-agents

clean:
	rm -rf $(BUILDDIR) lib .shards releases
