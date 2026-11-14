# Single command entrypoint for builds and checks: lint, build, test, audit, smoke, and perf.

# macOS ships Make 3.81, which ignores .SHELLFLAGS. Put these flags in SHELL so a
# compiler failure cannot be hidden by the tee pipeline in the build recipe.
SHELL := /bin/bash -eu -o pipefail

PROJECT := meters.xcodeproj
PACKAGE := Packages/MetersKit
DERIVED := build/DerivedData
RELEASE_APP := $(DERIVED)/Build/Products/Release/meters.app
PROBE := $(PACKAGE)/.build/release/meters-probe
SWIFT_SOURCES := App Tools $(PACKAGE)/Package.swift $(PACKAGE)/Sources $(PACKAGE)/Tests
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme meters -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet
STORE_DERIVED := build/AppStoreDerivedData
STORE_BUILD := xcodebuild -project $(PROJECT) -destination 'platform=macOS,arch=arm64' -derivedDataPath $(STORE_DERIVED) -quiet
STORE_VERSION ?= 1.0.0
STORE_BUILD_NUMBER ?= 2
STORE_ARCHIVE := build/Archives/meters-$(STORE_VERSION)-$(STORE_BUILD_NUMBER).xcarchive

.PHONY: help generate build test lint format probe audit smoke perf run stop clean app-store-build app-store-check app-store-archive

help:
	@echo "make build    Generate the Xcode project; build Debug and Release (warnings are errors)"
	@echo "make test     Run the MetersKit test suites"
	@echo "make lint     Check formatting with swift format (strict)"
	@echo "make format   Apply swift format fixes in place"
	@echo "make audit    Check the Release app for private frameworks, networking, and entitlements"
	@echo "make smoke    Launch the Release app in isolated settings and check it starts cleanly"
	@echo "make perf     Measure time to first data, CPU, and memory over 5 minutes"
	@echo "make run      Build and open the Release app with your own settings"
	@echo "make stop     Quit any running meters instance"
	@echo "make app-store-build  Build a development-signed sandbox compatibility app"
	@echo "make app-store-check  Audit and exercise the sandbox build and real metric sources"
	@echo "make app-store-archive  Create a local release candidate archive (STORE_BUILD_NUMBER=2 by default)"

generate:
	xcodegen generate --quiet

# Swift keeps strict-concurrency diagnostics that AppKit's annotations downgrade (for example, overriding
# a nonisolated accessibility method) as warnings even when warnings are errors, so also fail on any
# warning in this repository's sources. Files that warned are touched, so a rebuild without changes
# compiles them again and reports the same warnings instead of passing.
# The checkout's path reaches awk through the environment and is compared as text, not as a pattern or shell
# quoting, so a checkout under a folder such as "meters (1)", "c++", "My Projects", or "Tony's Mac" is checked too.
export WARNING_ROOT := $(CURDIR)/
WARNINGS := awk 'index($$0, ENVIRON["WARNING_ROOT"]) == 1 \
	&& substr($$0, length(ENVIRON["WARNING_ROOT"]) + 1) ~ /^[^:]+:[0-9]+:[0-9]+: warning:/' build/xcodebuild.log

build: generate
	@mkdir -p build
	$(XCODEBUILD) -configuration Debug build 2>&1 | tee build/xcodebuild.log
	$(XCODEBUILD) -configuration Release build 2>&1 | tee -a build/xcodebuild.log
	@warnings="$$($(WARNINGS))"; if [ -n "$$warnings" ]; then \
		echo "$$warnings"; \
		echo "$$warnings" | sed -E 's/:[0-9]+:[0-9]+: warning:.*//' | sort -u | tr '\n' '\0' | xargs -0 touch; \
		echo "error: compiler warnings in project sources"; exit 1; fi

# Tests use throwaway settings domains. The preferences daemon can write their emptied files after a
# test ends, so sweep them once the run finishes, whether it passed or not.
# The live accuracy checks measure the whole Mac, so they run in a pass of their own after the rest. Swift 6.3
# runs every test target in one parallel pass, and the other suites' work would show up in their CPU readings.
test:
	status=0; swift test --package-path $(PACKAGE) --skip LiveTests || status=$$?; \
		swift test --package-path $(PACKAGE) --skip-build --filter LiveTests || status=$$?; \
		sleep 1; rm -f "$$HOME"/Library/Preferences/net.1x0.meters.tests.*.plist; exit $$status

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

probe:
	swift build --package-path $(PACKAGE) -c release --product meters-probe

audit: build
	scripts/audit.sh $(RELEASE_APP)

smoke: build probe
	scripts/smoke.sh $(RELEASE_APP) $(PROBE)

perf: build probe
	scripts/perf.sh $(RELEASE_APP) $(PROBE)

run: build
	open $(RELEASE_APP)

app-store-build: generate
	@mkdir -p build
	$(STORE_BUILD) -scheme meters -configuration AppStore build 2>&1 | tee build/app-store-build.log

app-store-check: app-store-build probe
	$(STORE_BUILD) -scheme meters-sandbox-check -configuration Release build 2>&1 | tee build/app-store-diagnostic-build.log
	$(STORE_BUILD) -scheme meters-sandbox-check -configuration AppStore build 2>&1 | tee -a build/app-store-diagnostic-build.log
	scripts/app-store-check.sh $(STORE_DERIVED)/Build/Products $(PROBE)

app-store-archive: generate
	@mkdir -p build/Archives
	$(STORE_BUILD) -scheme meters -configuration AppStore -archivePath $(STORE_ARCHIVE) \
		MARKETING_VERSION=$(STORE_VERSION) CURRENT_PROJECT_VERSION=$(STORE_BUILD_NUMBER) archive \
		2>&1 | tee build/app-store-archive.log
	scripts/audit.sh $(STORE_ARCHIVE)/Products/Applications/meters.app --app-store

stop:
	pkill -x meters || true

clean:
	rm -rf build $(PROJECT) $(PACKAGE)/.build
