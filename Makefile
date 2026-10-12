APP := Mileage
BUNDLE := $(APP).app
CONFIG ?= release
## Stamped into the bundle. Releases pass the tag's version; local builds stay "dev".
VERSION ?= dev
ARCH_FLAGS ?=
DIST := dist

.PHONY: all build app run stop test lint release clean

all: app

build:
	swift build -c $(CONFIG) $(ARCH_FLAGS)

## Assemble a real .app bundle. Needed because LSUIElement (no Dock icon) and Keychain
## access both come from the bundle, not from the bare executable.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp "$$(swift build -c $(CONFIG) $(ARCH_FLAGS) --show-bin-path)/$(APP)" $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(BUNDLE)/Contents/Info.plist
	# Ad-hoc signature with a stable identifier so Keychain items survive rebuilds.
	codesign --force --sign - --identifier com.e7nt.mileage $(BUNDLE)

run: app
	@pkill -x $(APP) 2>/dev/null || true
	open $(BUNDLE)

stop:
	@pkill -x $(APP) 2>/dev/null || true

test:
	swift test

lint:
	swiftformat --lint . && swiftlint

## Universal (Apple silicon + Intel) zip and its checksum: what the installer downloads.
release:
	@echo "$(VERSION)" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
		|| { echo "usage: make release VERSION=x.y.z"; exit 1; }
	$(MAKE) app VERSION=$(VERSION) ARCH_FLAGS="--arch arm64 --arch x86_64"
	rm -rf $(DIST) && mkdir -p $(DIST)
	ditto -c -k --keepParent $(BUNDLE) $(DIST)/$(APP)-$(VERSION).zip
	cd $(DIST) && shasum -a 256 $(APP)-$(VERSION).zip > $(APP)-$(VERSION).zip.sha256

clean:
	rm -rf .build $(BUNDLE) $(DIST)
