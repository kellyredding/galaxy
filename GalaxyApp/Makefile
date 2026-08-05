.PHONY: generate build release clean validate-js smoke smoke-keystrokes check

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

# Sandboxed smoke checks: build the standalone tools and run them. No app
# launch — each runs as its own process. A dispatcher with one sibling today,
# shaped like assist-ant's so a second tool is a line here rather than a
# restructure.
smoke: smoke-keystrokes

# The ⌘/ catalog and its availability gates. Links Galactic so the concept
# searches run through the real matcher and the real glyph table, which is why
# the run step needs DYLD_FRAMEWORK_PATH — the same reason assist-ant's
# ItemsSmoke does.
smoke-keystrokes: generate
	xcodebuild -scheme KeystrokeSmoke -configuration Debug -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' build
	DYLD_FRAMEWORK_PATH="$(DERIVED_DATA)/Build/Products/Debug/PackageFrameworks" \
	  ./$(DERIVED_DATA)/Build/Products/Debug/KeystrokeSmoke

# The pre-commit gate: everything that can fail without launching the app.
#
# The keystroke *matcher* is still not checked here, and must not be: both
# halves of it — the Swift one and its JavaScript twin — live in Galactic and
# are asserted against a single fixture in a single process by `swift test`
# there. What `smoke` checks is this app's own ⌘/ catalog and the availability
# gates it restates from MainMenu, which nothing outside this repo can see.
check: build smoke

clean:
	xcodebuild -scheme GalaxyApp -derivedDataPath $(DERIVED_DATA) clean
	rm -rf $(DERIVED_DATA)
