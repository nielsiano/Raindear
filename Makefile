APP := build/Rain.app

.PHONY: app run install test clean

app:
	swift build -c release --product Rain
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release --show-bin-path)/Rain" $(APP)/Contents/MacOS/Rain
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	rm -rf /Applications/Rain.app
	cp -R $(APP) /Applications/Rain.app
	open /Applications/Rain.app

test:
	swift test -c release

clean:
	rm -rf .build build
