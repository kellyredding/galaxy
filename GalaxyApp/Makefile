.PHONY: build release clean

# Always use -derivedDataPath to avoid polluting ~/Library/Developer/Xcode/DerivedData
DERIVED_DATA = build

build:
	xcodebuild -scheme GalaxyApp -configuration Debug -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

release:
	xcodebuild -scheme GalaxyApp -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

clean:
	xcodebuild -scheme GalaxyApp -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
