.PHONY: all clean audit check statusline-build statusline-dev statusline-test statusline-check statusline-install statusline-clean ledger-build ledger-dev ledger-test ledger-check ledger-install ledger-clean snapshots-build snapshots-dev snapshots-test snapshots-check snapshots-install snapshots-clean artifacts-build artifacts-dev artifacts-test artifacts-check artifacts-install artifacts-clean timeline-build timeline-dev timeline-test timeline-check timeline-install timeline-clean agents-build agents-dev agents-test agents-check agents-install agents-clean diff-build diff-dev diff-test diff-check diff-install diff-clean galaxy-build galaxy-dev galaxy-test galaxy-check galaxy-install galaxy-clean app-build app-smoke app-check app-release app-clean

all: statusline-build ledger-build snapshots-build artifacts-build timeline-build agents-build diff-build galaxy-build

# Statusline tool
statusline-build:
	$(MAKE) -C tools/statusline build

statusline-dev:
	$(MAKE) -C tools/statusline dev

statusline-test:
	$(MAKE) -C tools/statusline test

statusline-check:
	$(MAKE) -C tools/statusline check

statusline-install:
	$(MAKE) -C tools/statusline install

statusline-clean:
	$(MAKE) -C tools/statusline clean

# Ledger tool
ledger-build:
	$(MAKE) -C tools/ledger build

ledger-dev:
	$(MAKE) -C tools/ledger dev

ledger-test:
	$(MAKE) -C tools/ledger test

ledger-check:
	$(MAKE) -C tools/ledger check

ledger-install:
	$(MAKE) -C tools/ledger install

ledger-clean:
	$(MAKE) -C tools/ledger clean

# Snapshots tool
snapshots-build:
	$(MAKE) -C tools/snapshots build

snapshots-dev:
	$(MAKE) -C tools/snapshots dev

snapshots-test:
	$(MAKE) -C tools/snapshots test

snapshots-check:
	$(MAKE) -C tools/snapshots check

snapshots-install:
	$(MAKE) -C tools/snapshots install

snapshots-clean:
	$(MAKE) -C tools/snapshots clean

# Artifacts tool
artifacts-build:
	$(MAKE) -C tools/artifacts build

artifacts-dev:
	$(MAKE) -C tools/artifacts dev

artifacts-test:
	$(MAKE) -C tools/artifacts test

artifacts-check:
	$(MAKE) -C tools/artifacts check

artifacts-install:
	$(MAKE) -C tools/artifacts install

artifacts-clean:
	$(MAKE) -C tools/artifacts clean

# Timeline tool
timeline-build:
	$(MAKE) -C tools/timeline build

timeline-dev:
	$(MAKE) -C tools/timeline dev

timeline-test:
	$(MAKE) -C tools/timeline test

timeline-check:
	$(MAKE) -C tools/timeline check

timeline-install:
	$(MAKE) -C tools/timeline install

timeline-clean:
	$(MAKE) -C tools/timeline clean

# Agents tool
agents-build:
	$(MAKE) -C tools/agents build

agents-dev:
	$(MAKE) -C tools/agents dev

agents-test:
	$(MAKE) -C tools/agents test

agents-check:
	$(MAKE) -C tools/agents check

agents-install:
	$(MAKE) -C tools/agents install

agents-clean:
	$(MAKE) -C tools/agents clean

# Diff tool
diff-build:
	$(MAKE) -C tools/diff build

diff-dev:
	$(MAKE) -C tools/diff dev

diff-test:
	$(MAKE) -C tools/diff test

diff-check:
	$(MAKE) -C tools/diff check

diff-install:
	$(MAKE) -C tools/diff install

diff-clean:
	$(MAKE) -C tools/diff clean

# Galaxy orchestrator CLI
galaxy-build:
	$(MAKE) -C tools/galaxy build

galaxy-dev:
	$(MAKE) -C tools/galaxy dev

galaxy-test:
	$(MAKE) -C tools/galaxy test

galaxy-check:
	$(MAKE) -C tools/galaxy check

galaxy-install:
	$(MAKE) -C tools/galaxy install

galaxy-clean:
	$(MAKE) -C tools/galaxy clean

# Galaxy.app (SwiftUI Mac app)
# Delegated so the embedded-JavaScript syntax gate runs here too. Calling
# xcodebuild directly from this file skipped validate-js, leaving a gate that
# only fired when the app was built from its own directory. Derived data still
# lands in GalaxyApp/build either way.
app-build:
	$(MAKE) -C GalaxyApp build

# Delegated for the same reason app-build is: the smoke tool's run step uses a
# path relative to GalaxyApp/, and `check` there is build + smoke — which is
# where the JavaScript syntax gate runs.
app-smoke:
	$(MAKE) -C GalaxyApp smoke

app-check:
	$(MAKE) -C GalaxyApp check

app-release:
	$(MAKE) -C GalaxyApp release

app-clean:
	$(MAKE) -C GalaxyApp clean

clean: statusline-clean ledger-clean snapshots-clean artifacts-clean timeline-clean agents-clean diff-clean galaxy-clean app-clean

# --- Disclosure audit ---

# Refuses employer- and deployment-specific details in tracked files. This
# repository is public, and example output and spec fixtures are where such
# details arrive by accident — the easiest example to write is whatever was on
# screen at the time.
#
# A leak cannot be undone by a later commit, so the only useful time to catch
# one is before it is committed. Run this before committing, not after.
audit:
	./scripts/check-disclosure.sh

# The pre-commit gate: the audit, then every tool's own lint + build + specs.
#
# Deliberately not wired into `all`, which is a build target — but the audit is
# worth running on its own far more often than this, since `check` takes a few
# minutes with the ledger suite in it.
check: audit statusline-check ledger-check snapshots-check artifacts-check timeline-check agents-check diff-check galaxy-check
