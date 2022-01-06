BUILD_DIR = ./Build

MACOS_DERIVED_DIR = $(BUILD_DIR)/macOS
MACOS_DESTINATION = "generic/platform=macOS,name=Any Mac"

IOS_DERIVED_DIR = $(BUILD_DIR)/iOS
IOS_DESTINATION = "generic/platform=iOS,name=Any iOS Device"

clean:
	rm -rf barcelona.xcodeproj Build

soft-clean:
	rm -rf barcelona.xcodeproj

init:
	vendor/xcodegen generate
	
refresh:
	vendor/xcodegen generate

scheme:
	xcodebuild \
		-project barcelona.xcodeproj \
		-scheme "$(SCHEME)" \
		-parallelizeTargets \
		-jobs 8 \
		-destination "$(DESTINATION)" \
		-configuration Release \
		-derivedDataPath $(DERIVED_DIR) \
		-ONLY_ACTIVE_ARCH=NO | xcpretty

scheme-macos:
	$(MAKE) scheme DESTINATION=$(MACOS_DESTINATION) DERIVED_DIR=$(MACOS_DERIVED_DIR)

scheme-ios:
	$(MAKE) scheme DESTINATION=$(IOS_DESTINATION) DERIVED_DIR=$(IOS_DERIVED_DIR)

mautrix-macos:
	$(MAKE) scheme-macos SCHEME=barcelona-mautrix

grapple-macos:
	$(MAKE) scheme-macos SCHEME=grapple

mautrix-ios:
	$(MAKE) scheme-ios SCHEME=barcelona-mautrix

grapple-ios:
	$(MAKE) scheme-ios SCHEME=grapple

ios:
	$(MAKE) scheme-ios SCHEME=ci-ios
	
macos:
	$(MAKE) scheme-macos SCHEME=ci-macos
