# Single command entrypoint for builds and checks: lint, build, test, audit, smoke, and perf.

# macOS ships Make 3.81, which ignores .SHELLFLAGS. Put these flags in SHELL so a
# compiler failure cannot be hidden by the tee pipeline in the build recipe.
SHELL := /bin/bash -eu -o pipefail

PROJECT := meters.xcodeproj
PACKAGE := Packages/MetersKit
DERIVED := build/DerivedData
RELEASE_APP := $(DERIVED)/Build/Products/Release/meters.app
PROBE := $(PACKAGE)/.build/release/meters-probe
SWIFT_SOURCES := App $(PACKAGE)/Package.swift $(PACKAGE)/Sources $(PACKAGE)/Tests
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme meters -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet

.PHONY: help generate build test lint format probe audit smoke perf run stop clean

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

generate:
	xcodegen generate --quiet

# Swift keeps strict-concurrency diagnostics that AppKit's annotations downgrade (for example, overriding
# a nonisolated accessibility method) as warnings even when warnings are errors, so also fail on any
# warning in this repository's sources. Files that warned are touched, so a rebuild without changes
# compiles them again and reports the same warnings instead of passing.
WARNING_LINE := ^$(CURDIR)/[^:]+:[0-9]+:[0-9]+: warning:

build: generate
	@mkdir -p build
	$(XCODEBUILD) -configuration Debug build 2>&1 | tee build/xcodebuild.log
	$(XCODEBUILD) -configuration Release build 2>&1 | tee -a build/xcodebuild.log
	@if grep -E '$(WARNING_LINE)' build/xcodebuild.log; then \
		grep -E '$(WARNING_LINE)' build/xcodebuild.log | cut -d: -f1 | sort -u | xargs touch; \
		echo "error: compiler warnings in project sources"; exit 1; fi

# Tests use throwaway settings domains. The preferences daemon can write their emptied files after a
# test ends, so sweep them once the run finishes, whether it passed or not.
test:
	status=0; swift test --package-path $(PACKAGE) || status=$$?; \
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

stop:
	pkill -x meters || true

clean:
	rm -rf build $(PROJECT) $(PACKAGE)/.build
