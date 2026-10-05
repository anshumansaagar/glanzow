# Glanzow build. `make app` builds a signed .app; see README for signing and notarization.
CONFIG     ?= release
APP        := build/Glanzow.app
BUNDLE_ID  := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)
# Prefer Developer ID, then Apple Development, then ad-hoc ("-"). A real certificate keeps the
# code identity stable, so camera and Accessibility grants survive rebuilds.
SIGN_ID    ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{d=$$2} /Apple Development/{a=$$2} END{print (d!="" ? d : (a!="" ? a : "-"))}')
TIMESTAMP  ?= --timestamp=none
NOTARY_PROFILE ?= glanzow-notary

.PHONY: app run test replay dmg notarize reset-permissions diagnostics clean

app:
	swift build -c $(CONFIG) --product Glanzow
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/Glanzow" $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	codesign --force --options runtime $(TIMESTAMP) --entitlements Resources/Glanzow.entitlements --sign "$(SIGN_ID)" $(APP)
	@echo "Built $(APP) (signed: $(SIGN_ID))"

run: app
	open $(APP)

test:
	swift test

# make replay FILE=~/Library/Application\ Support/Glanzow/Recordings/pose-....json ARGS="--dwell 400"
replay:
	swift run -c release ReplayCLI "$(FILE)" $(ARGS)

dmg: app
	rm -f build/Glanzow.dmg
	hdiutil create -volname Glanzow -srcfolder $(APP) -ov -format UDZO build/Glanzow.dmg
	codesign --force $(TIMESTAMP) --sign "$(SIGN_ID)" build/Glanzow.dmg

# make notarize SIGN_ID="Developer ID Application: Name (TEAMID)"
notarize:
	$(MAKE) dmg TIMESTAMP=--timestamp
	xcrun notarytool submit build/Glanzow.dmg --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple build/Glanzow.dmg

reset-permissions:
	-tccutil reset Camera $(BUNDLE_ID)
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset ListenEvent $(BUNDLE_ID)

# One text file on the Desktop with settings, calibration, switch timings, CPU and logs.
diagnostics:
	@scripts/diagnostics.sh

clean:
	rm -rf build .build
