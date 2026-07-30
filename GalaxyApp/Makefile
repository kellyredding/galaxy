.PHONY: generate build release clean validate-js check

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

build: generate validate-js
	xcodebuild -scheme GalaxyApp -configuration Debug -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

release: generate validate-js
	xcodebuild -scheme GalaxyApp -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build

# The pre-commit gate: everything that can fail without launching the app.
#
# The keystroke matchers are no longer checked here. Both of them — the Swift
# one and its JavaScript twin — now live in Galactic and are asserted against a
# single fixture in a single process by `swift test` there. Re-checking either
# half from this side would mean a second copy of the fixture, which is the
# thing that arrangement exists to prevent.
check: build

clean:
	xcodebuild -scheme GalaxyApp -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
