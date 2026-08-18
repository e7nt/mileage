APP := Mileage
BUNDLE := $(APP).app
CONFIG ?= release
BIN := .build/$(CONFIG)/$(APP)

.PHONY: all build app run stop test lint clean

all: app

build:
	swift build -c $(CONFIG)

## Assemble a real .app bundle. Needed because LSUIElement (no Dock icon) and Keychain
## access both come from the bundle, not from the bare executable.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
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

clean:
	rm -rf .build $(BUNDLE)
