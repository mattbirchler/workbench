PROJECT = Bench.xcodeproj
SCHEME = Bench
DERIVED = build
# Coverage instrumentation off for the Swift packages too (project.yml
# covers Workbench's own targets): with it on, a binary writes
# default.profraw into its working directory when it exits.
# The Mac Live Activity needs the macOS 27.3 SDK. Until Xcode 27.3 is out,
# the Mac app builds with its beta when that's installed and DEVELOPER_DIR
# isn't set. Without it everything still builds, minus the Live Activity.
# Public releases (scripts/notarize.sh) don't go through this.
ifeq ($(origin DEVELOPER_DIR),undefined)
ifneq ($(wildcard /Applications/Xcode-beta.app/Contents/Developer),)
MAC_XCODE = DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
endif
endif
XCODEBUILD = $(MAC_XCODE) xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO

.PHONY: ghostty generate build test run install install-codex release dmg notarize publish website dsyms phone phone-install clean

# Build libghostty from source into vendor/. Needed once before `make build`.
ghostty:
	scripts/build-ghostty.sh

generate:
	xcodegen generate

# Build output is filtered to errors, app-source warnings, and the result line,
# but the exit status is xcodebuild's so failures stop whatever invoked make.
build: generate
	@mkdir -p $(DERIVED)
	@$(XCODEBUILD) -configuration Debug build > $(DERIVED)/last-build.log 2>&1; status=$$?; \
	grep -E "error:|warning:.*Bench/Bench/|BUILD (SUCCEEDED|FAILED)" $(DERIVED)/last-build.log | sort -u; \
	exit $$status

# The Mac app's own tests (BenchTests), in the built app. BenchKit's tests
# run with `swift test` in BenchKit. The host app stays inert under the
# harness (see TestHost.swift), and anything that still reaches for the
# support folder lands in the build folder, not the real one.
test: generate
	@mkdir -p $(DERIVED)
	@TEST_RUNNER_BENCH_SUPPORT_DIR=$(abspath $(DERIVED))/test-support $(MAC_XCODE) xcodebuild -project $(PROJECT) -scheme BenchTests -derivedDataPath $(DERIVED) -configuration Debug -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO COMPILER_INDEX_STORE_ENABLE=NO test > $(DERIVED)/last-test.log 2>&1; status=$$?; \
	grep -E "error:|Test run|􁁛|􀢄|TEST (SUCCEEDED|FAILED)" $(DERIVED)/last-test.log | sort -u | tail -40; \
	exit $$status

run: build
	@pkill -x Workbench || true
	open $(DERIVED)/Build/Products/Debug/Workbench.app

# Release build copied into /Applications.
install: generate
	@mkdir -p $(DERIVED)
	@$(XCODEBUILD) -configuration Release build > $(DERIVED)/last-release.log 2>&1; status=$$?; \
	grep -E "error:|BUILD (SUCCEEDED|FAILED)" $(DERIVED)/last-release.log | sort -u; \
	exit $$status
	@rm -rf /Applications/Bench.app /Applications/Workbench.app
	cp -R $(DERIVED)/Build/Products/Release/Workbench.app /Applications/Workbench.app
	@echo "Installed /Applications/Workbench.app"

# A second copy, "Workbench Beta", with its own bundle id so it keeps its
# own settings (Application Support/Bench-beta and its own defaults), listens
# on its own port, never checks for updates, and runs beside the installed
# app. It's the normal Release build renamed afterwards and signed again
# with the same identity: setting PRODUCT_NAME on the xcodebuild command
# line would rename every package bundle too and make them collide. The
# first install copies the real app's project list over. The executable
# inside is still called Workbench, so `make run` quits the beta too.
BETA_APP = /Applications/Workbench Beta.app
install-beta: release
	@rm -rf "$(BETA_APP)"
	cp -R $(DERIVED)/Build/Products/Release/Workbench.app "$(BETA_APP)"
	@plutil -replace CFBundleIdentifier -string me.birchtree.Bench.beta "$(BETA_APP)/Contents/Info.plist"
	@plutil -replace CFBundleName -string "Workbench Beta" "$(BETA_APP)/Contents/Info.plist"
	@plutil -replace CFBundleDisplayName -string "Workbench Beta" "$(BETA_APP)/Contents/Info.plist"
	@identity=$$(codesign -dvv $(DERIVED)/Build/Products/Release/Workbench.app 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-); \
	echo "Signing as $${identity:-ad hoc}"; \
	codesign --force --deep --options runtime --preserve-metadata=entitlements,flags --sign "$${identity:--}" "$(BETA_APP)"
	@python3 scripts/seed-beta.py "$(HOME)/Library/Application Support/Bench/state.json" "$(HOME)/Library/Application Support/Bench-beta/state.json"
	@echo "Installed $(BETA_APP)"

# A third copy for trying Codex support beside the real app: Codexbench,
# with its own icon (light, with black artwork) so the two are easy to tell
# apart. Like the beta it keeps its own data (Bench-codex in Application
# Support), never updates itself, and starts with the real app's projects.
# It isn't for release. The icon is compiled on its own and swapped in, so
# nothing of it ships in Workbench. Nothing is deleted: the copy is put
# together in a new folder under build/, and a copy already installed is
# moved aside into build/ before the new one takes its place.
CODEX_APP = /Applications/Codexbench.app
install-codex: release
	@stage=$$(mktemp -d $(DERIVED)/codex-stage.XXXXXX); app="$$stage/Codexbench.app"; \
	cp -R $(DERIVED)/Build/Products/Release/Workbench.app "$$app"; \
	xcrun actool codexbench-icon.icon --compile "$$stage" --app-icon codexbench-icon --platform macosx \
		--minimum-deployment-target 14.0 --output-partial-info-plist "$$stage/partial.plist" > /dev/null; \
	cp "$$stage/codexbench-icon.icns" "$$app/Contents/Resources/codexbench-icon.icns"; \
	plutil -replace CFBundleIconFile -string codexbench-icon "$$app/Contents/Info.plist"; \
	plutil -remove CFBundleIconName "$$app/Contents/Info.plist" 2>/dev/null || true; \
	plutil -replace CFBundleIdentifier -string me.birchtree.Bench.codex "$$app/Contents/Info.plist"; \
	plutil -replace CFBundleName -string "Codexbench" "$$app/Contents/Info.plist"; \
	plutil -replace CFBundleDisplayName -string "Codexbench" "$$app/Contents/Info.plist"; \
	identity=$$(codesign -dvv $(DERIVED)/Build/Products/Release/Workbench.app 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-); \
	echo "Signing as $${identity:-ad hoc}"; \
	codesign --force --deep --options runtime --preserve-metadata=entitlements,flags --sign "$${identity:--}" "$$app"; \
	if [ -e "$(CODEX_APP)" ]; then mv "$(CODEX_APP)" "$$stage/previous.app"; fi; \
	mv "$$app" "$(CODEX_APP)"
	@python3 scripts/seed-beta.py "$(HOME)/Library/Application Support/Bench/state.json" "$(HOME)/Library/Application Support/Bench-codex/state.json"
	@touch "$(CODEX_APP)"
	@echo "Installed $(CODEX_APP)"

# Release build only, without installing it.
release: generate
	@mkdir -p $(DERIVED)
	@$(XCODEBUILD) -configuration Release build > $(DERIVED)/last-release.log 2>&1; status=$$?; \
	grep -E "error:|BUILD (SUCCEEDED|FAILED)" $(DERIVED)/last-release.log | sort -u; \
	exit $$status

# The install disk image, unsigned, from a Release build, to check how it
# looks: build/Workbench.dmg. `make notarize` makes the signed one.
dmg: release
	@scripts/make-dmg.sh $(DERIVED)/Build/Products/Release/Workbench.app $(DERIVED)/Workbench.dmg

# A Release build signed with Developer ID and notarized by Apple, zipped
# in build/notarized/ so it opens on any Mac. Needs fastlane/.env.
notarize:
	@scripts/notarize.sh

# Ship a new version to every Mac through Sparkle. Needs release notes:
#   make publish NOTES=notes.md [VERSION=0.3]
publish:
	@NOTES="$(NOTES)" VERSION="$(VERSION)" scripts/publish.sh

# Puts website/ live on GitHub Pages (the gh-pages branch) without shipping a
# new version of the app. publish does this on its own.
website:
	@scripts/publish-website.sh

# Uploads the last notarized build's debug symbols to PostHog, for when
# `make publish` ran with SKIP_DSYMS=1. publish does this on its own.
dsyms:
	@scripts/upload-dsyms.sh build/notarized/Bench.xcarchive/dSYMs me.birchtree.Bench

# The iPhone companion. `phone` compiles it for the simulator;
# `phone-install` builds for a real iPhone and installs it over Xcode's
# device connection (USB or Wi-Fi). Pick the phone with PHONE="name".
PHONE ?= Matt’s iPhone 18
XCODEBUILD_PHONE = xcodebuild -project $(PROJECT) -scheme BenchPhone -derivedDataPath $(DERIVED)

phone: generate
	@mkdir -p $(DERIVED)
	@$(XCODEBUILD_PHONE) -destination 'generic/platform=iOS Simulator' -configuration Debug build > $(DERIVED)/last-phone.log 2>&1; status=$$?; \
	grep -E "error:|warning:.*Bench/BenchPhone/|BUILD (SUCCEEDED|FAILED)" $(DERIVED)/last-phone.log | sort -u; \
	exit $$status

phone-install: generate
	@mkdir -p $(DERIVED)
	@$(XCODEBUILD_PHONE) -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build > $(DERIVED)/last-phone-release.log 2>&1; status=$$?; \
	grep -E "error:|BUILD (SUCCEEDED|FAILED)" $(DERIVED)/last-phone-release.log | sort -u; \
	exit $$status
	xcrun devicectl device install app --device "$(PHONE)" $(DERIVED)/Build/Products/Release-iphoneos/Bench.app

clean:
	rm -rf $(DERIVED) $(PROJECT)
