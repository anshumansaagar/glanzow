# GlanceFocus build. `make app` builds a signed .app; see README for signing and notarization.
CONFIG     ?= release
APP        := build/GlanceFocus.app
BUNDLE_ID  := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)
# Prefer Developer ID, then Apple Development, then ad-hoc ("-"). A real certificate keeps the
# code identity stable, so camera and Accessibility grants survive rebuilds.
SIGN_ID    ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{d=$$2} /Apple Development/{a=$$2} END{print (d!="" ? d : (a!="" ? a : "-"))}')
TIMESTAMP  ?= --timestamp=none
NOTARY_PROFILE ?= glancefocus-notary

.PHONY: app run test replay dmg notarize reset-permissions clean

app:
	swift build -c $(CONFIG) --product GlanceFocus
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/GlanceFocus" $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	codesign --force --options runtime $(TIMESTAMP) --entitlements Resources/GlanceFocus.entitlements --sign "$(SIGN_ID)" $(APP)
	@echo "Built $(APP) (signed: $(SIGN_ID))"

run: app
	open $(APP)

test:
	swift test

# make replay FILE=~/Library/Application\ Support/GlanceFocus/Recordings/pose-....json ARGS="--dwell 400"
replay:
	swift run -c release ReplayCLI "$(FILE)" $(ARGS)

dmg: app
	rm -f build/GlanceFocus.dmg
	hdiutil create -volname GlanceFocus -srcfolder $(APP) -ov -format UDZO build/GlanceFocus.dmg
	codesign --force $(TIMESTAMP) --sign "$(SIGN_ID)" build/GlanceFocus.dmg

# make notarize SIGN_ID="Developer ID Application: Name (TEAMID)"
notarize:
	$(MAKE) dmg TIMESTAMP=--timestamp
	xcrun notarytool submit build/GlanceFocus.dmg --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple build/GlanceFocus.dmg

reset-permissions:
	-tccutil reset Camera $(BUNDLE_ID)
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset ListenEvent $(BUNDLE_ID)

clean:
	rm -rf build .build
