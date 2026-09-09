.PHONY: generate build test run install clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar -configuration Release build SYMROOT=build

test: generate
	xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

run: build
	open build/Release/QuotaBar.app

# Also stops/removes any pre-rename ClaudeUsageBar.app: both bundles share one bundle
# identifier and one Keychain item, so two installed copies would fight over them.
install: build
	-pkill -x QuotaBar || true
	-pkill -x ClaudeUsageBar || true
	rm -rf /Applications/QuotaBar.app /Applications/ClaudeUsageBar.app
	cp -R build/Release/QuotaBar.app /Applications/
	@echo "Installed to /Applications/QuotaBar.app"

clean:
	rm -rf build DerivedData QuotaBar.xcodeproj ClaudeUsageBar.xcodeproj
