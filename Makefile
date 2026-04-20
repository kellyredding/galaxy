.PHONY: all clean statusline-build statusline-test statusline-check statusline-install statusline-clean ledger-build ledger-test ledger-check ledger-install ledger-clean snapshots-build snapshots-dev snapshots-test snapshots-check snapshots-install snapshots-clean artifacts-build artifacts-dev artifacts-test artifacts-check artifacts-install artifacts-clean timeline-build timeline-dev timeline-test timeline-check timeline-install timeline-clean agents-build agents-dev agents-test agents-check agents-install agents-clean diff-build diff-dev diff-test diff-check diff-install diff-clean galaxy-build galaxy-dev galaxy-test galaxy-check galaxy-install galaxy-clean app-build app-clean

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
# Always uses -derivedDataPath to avoid polluting ~/Library/Developer/Xcode/DerivedData
APP_DERIVED_DATA = GalaxyApp/build

app-build:
	xcodebuild -project GalaxyApp/GalaxyApp.xcodeproj -scheme GalaxyApp -configuration Debug -derivedDataPath $(APP_DERIVED_DATA) -destination 'platform=macOS' build

app-release:
	xcodebuild -project GalaxyApp/GalaxyApp.xcodeproj -scheme GalaxyApp -configuration Release -derivedDataPath $(APP_DERIVED_DATA) -destination 'platform=macOS' build

app-clean:
	xcodebuild -project GalaxyApp/GalaxyApp.xcodeproj -scheme GalaxyApp -derivedDataPath $(APP_DERIVED_DATA) clean
	rm -rf $(APP_DERIVED_DATA)

clean: statusline-clean ledger-clean snapshots-clean artifacts-clean timeline-clean agents-clean diff-clean galaxy-clean app-clean
