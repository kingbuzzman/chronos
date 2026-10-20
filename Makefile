VERSION := $(shell cat VERSION)
# Everything a build makes goes in BUILD, so make clean deletes just that.
BUILD := build
# Every swift command takes it, so SwiftPM builds in BUILD rather than its default .build.
SWIFTPM := --scratch-path $(BUILD)/swiftpm
APP := $(BUILD)/Chronos.app
# The viewer, nested in the recorder's bundle so the two install, update and sign as one app.
VIEWER := $(APP)/Contents/Helpers/Chronos.app
PREFIX ?= $(HOME)/Applications
# The first Apple Development identity in the keychain, if any: macOS ties Accessibility and Automation to it, so they
# survive rebuilds. Without one, "-" signs ad hoc, which macOS treats as a new app on every build, and both have to be
# allowed again after each one. Override with make SIGN_IDENTITY="…".
SIGN_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"'),-)
SOURCES := Package.swift $(shell find Sources -type f)
# Drawn by IconMaker from Sources/ChronosCore/Logo.swift, the same code that draws the menu bar icon.
ICON := $(BUILD)/AppIcon.icns
RESOURCES := $(wildcard Resources/*)
# chronos-ff, the Firefox extension, and what Firefox needs to find its helper inside the app. Firefox only looks for
# helpers in FF_HOSTS, outside the project: make ff-register writes the one file there, pointing at a Chronos.app.
FF := chronos-ff
FF_SOURCES := $(FF)/manifest.json $(FF)/domain.js $(FF)/background.js
FF_XPI := $(BUILD)/chronos-ff.xpi
FF_HOSTS := $(HOME)/Library/Application Support/Mozilla/NativeMessagingHosts
FF_REGISTRATION := com.kingbuzzman.chronos.json
# Every build goes through it: a single warning, from any tool, fails the build.
STRICT := scripts/no-warnings.sh
# Runs the tests under a pseudo-terminal, so their progress is printed as it happens.
UNBUFFERED := script -q /dev/null

all: $(APP) $(FF_XPI)

# All three executables into one bundle, signed inside out: the nested viewer and Firefox helper first, then the
# recorder around them. install -S replaces each file rather than writing over it, so rebuilding while Chronos runs
# doesn't crash it.
$(APP): $(SOURCES) $(RESOURCES) $(ICON) VERSION Makefile
	$(STRICT) swift build $(SWIFTPM) -c release
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(VIEWER)/Contents/MacOS $(VIEWER)/Contents/Resources
	install -S -m 644 $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	install -S -m 644 $(ICON) $(VIEWER)/Contents/Resources/AppIcon.icns
	install -S -m 755 "$$(swift build $(SWIFTPM) -c release --show-bin-path)/Chronos" $(APP)/Contents/MacOS/Chronos
	install -S -m 755 "$$(swift build $(SWIFTPM) -c release --show-bin-path)/ChronosViewer" \
		$(VIEWER)/Contents/MacOS/ChronosViewer
	install -S -m 755 "$$(swift build $(SWIFTPM) -c release --show-bin-path)/chronos-ff-host" \
		$(APP)/Contents/Helpers/chronos-ff-host
	install -S -m 644 Resources/Chronos-Info.plist $(APP)/Contents/Info.plist
	install -S -m 644 Resources/Viewer-Info.plist $(VIEWER)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(VIEWER)/Contents/Info.plist
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime $(VIEWER)
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime --identifier com.kingbuzzman.chronos.ff-host \
		$(APP)/Contents/Helpers/chronos-ff-host
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime --entitlements Resources/Chronos.entitlements $(APP)
	touch $(APP)

$(ICON): Sources/ChronosCore/Logo.swift Sources/IconMaker/main.swift
	$(STRICT) swift build $(SWIFTPM) -c release --product IconMaker
	"$$(swift build $(SWIFTPM) -c release --show-bin-path)/IconMaker" $(BUILD)/AppIcon.iconset
	iconutil --convert icns --output $@ $(BUILD)/AppIcon.iconset

# The extension, packaged for Firefox. Until it's signed by Mozilla, regular Firefox only loads it temporarily: in
# about:debugging → This Firefox → Load Temporary Add-on, pick this file (or chronos-ff/manifest.json).
$(FF_XPI): $(FF_SOURCES) VERSION
	mkdir -p $(BUILD)/ff
	sed 's/"version": "[^"]*"/"version": "$(VERSION)"/' $(FF)/manifest.json > $(BUILD)/ff/manifest.json
	cp $(FF)/domain.js $(FF)/background.js $(BUILD)/ff/
	cd $(BUILD)/ff && zip -q -X -r ../chronos-ff.xpi manifest.json domain.js background.js

# Tells Firefox where chronos-ff's helper is: this build's Chronos.app, or another with
# make ff-register CHRONOS_APP=~/Applications/Chronos.app. Writes the one file outside the project, in FF_HOSTS.
CHRONOS_APP ?= $(CURDIR)/$(APP)
ff-register: $(APP)
	mkdir -p $(BUILD)/ff
	sed 's|HELPER_PATH|$(abspath $(CHRONOS_APP))/Contents/Helpers/chronos-ff-host|' Resources/firefox-native-host.json \
		> $(BUILD)/ff/$(FF_REGISTRATION)
	mkdir -p "$(FF_HOSTS)"
	cp $(BUILD)/ff/$(FF_REGISTRATION) "$(FF_HOSTS)/$(FF_REGISTRATION)"

# Runs Chronos from the build folder, against a database in it rather than the real one. Through open, so Chronos asks
# for its permissions itself: started from a terminal, macOS would ask on the terminal's behalf.
run: $(APP)
	open --env CHRONOS_DATABASE=$(CURDIR)/$(BUILD)/chronos.sqlite $(APP)

# Unit tests of ChronosCore, then chronos-ff's; run a subset of the first with: make test TESTS=TrackerTests
test:
	$(STRICT) swift build $(SWIFTPM) --build-tests
	$(UNBUFFERED) swift test $(SWIFTPM) --skip-build $(if $(TESTS),--filter '$(TESTS)') </dev/null
	node --test $(FF)/*.test.js

format:
	swift format --recursive --in-place Package.swift Sources Tests

lint:
	swift format lint --recursive --strict Package.swift Sources Tests
	npx web-ext lint --source-dir=chronos-ff --warnings-as-errors

install: $(APP) $(FF_XPI)
	mkdir -p $(PREFIX)
	ditto $(APP) $(PREFIX)/Chronos.app

clean:
	rm -rf $(BUILD)

.PHONY: all run test format lint install clean ff-register
