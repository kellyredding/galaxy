.PHONY: all clean statusline-build statusline-test statusline-check statusline-install statusline-clean ledger-build ledger-test ledger-check ledger-install ledger-clean app-build app-clean

all: statusline-build ledger-build

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

clean: statusline-clean ledger-clean app-clean
