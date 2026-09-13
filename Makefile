APP := build/Raindear.app

.PHONY: app run install test clean

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

clean:
	rm -rf .build build
