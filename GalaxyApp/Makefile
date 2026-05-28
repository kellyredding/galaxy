.PHONY: build release clean validate-js

# Always use -derivedDataPath to avoid polluting ~/Library/Developer/Xcode/DerivedData
DERIVED_DATA = build

# Syntax-check the JavaScript that ships inside the app — standalone
# Resources/*.js plus JS embedded in Swift """ literals marked with a
# `// js-validate` comment. xcodebuild treats embedded JS as opaque
# string data, so this gate catches syntax errors that would otherwise
# compile clean and only fail at runtime in the WebView.
validate-js:
	node scripts/validate-js.mjs

build: validate-js
	xcodebuild -scheme GalaxyApp -configuration Debug -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

release: validate-js
	xcodebuild -scheme GalaxyApp -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

clean:
	xcodebuild -scheme GalaxyApp -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
