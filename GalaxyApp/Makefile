.PHONY: generate build release clean validate-js verify-text-entry smoke check

# Always use -derivedDataPath to avoid polluting ~/Library/Developer/Xcode/DerivedData
DERIVED_DATA = build

# project.yml is the source of truth; the generated project file is
# gitignored. Without this a fresh clone has no project to build at all, and
# an edited project.yml is silently ignored in favour of whatever was last
# generated — so a dependency bump can appear to succeed while the build
# still links the previous version.
generate:
	xcodegen generate

# Syntax-check the JavaScript that ships inside the app — standalone
# Resources/*.js plus JS embedded in Swift """ literals marked with a
# `// js-validate` comment. xcodebuild treats embedded JS as opaque
# string data, so this gate catches syntax errors that would otherwise
# compile clean and only fail at runtime in the WebView.
validate-js:
	node scripts/validate-js.mjs

# Run the shipped JS text-entry matcher against the same fixture table the
# Swift smoke target uses. A build gate rather than part of `check`, for the
# same reason validate-js is one: the two matchers disagreeing is invisible at
# runtime until a key silently stops working inside a WebView composer.
verify-text-entry:
	node scripts/verify-text-entry.mjs

build: generate validate-js verify-text-entry
	xcodebuild -scheme GalaxyApp -configuration Debug -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

release: generate validate-js verify-text-entry
	xcodebuild -scheme GalaxyApp -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

# Build and run the keystroke smoke checks. Runs from this directory, so the
# fixture path the tool defaults to resolves.
smoke: generate
	xcodebuild -scheme KeystrokeSmoke -configuration Debug -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build
	./$(DERIVED_DATA)/Build/Products/Debug/KeystrokeSmoke

# The pre-commit gate: everything that can fail without launching the app.
check: build smoke

clean:
	xcodebuild -scheme GalaxyApp -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
