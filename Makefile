APP := build/Raindear.app
# A swift.org toolchain with the Swift SDK for WebAssembly installed. Xcode's swift cannot target wasm
SWIFT_WASM ?= swift
WASM_SDK ?= swift-6.4.0-RELEASE_wasm-embedded

.PHONY: app run install test wasm clean

app:
	swift build -c release --product Raindear
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release --show-bin-path)/Raindear" $(APP)/Contents/MacOS/Raindear
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	rm -rf /Applications/Raindear.app
	cp -R $(APP) /Applications/Raindear.app
	open /Applications/Raindear.app

test:
	swift test -c release

wasm:
	$(SWIFT_WASM) build -c release --product rain-wasm --swift-sdk $(WASM_SDK) --scratch-path .build-wasm
	cp .build-wasm/release/rain-wasm.wasm web/rain.wasm

clean:
	rm -rf .build .build-wasm build web/rain.wasm
