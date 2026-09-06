APP = AgentUsageBar
DEST = /Applications/$(APP).app

build:
	swift build -c release

install: build
	osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null || true
	rm -rf /Applications/ClaudeUsageBar.app
	rm -rf $(DEST)
	mkdir -p $(DEST)/Contents/MacOS $(DEST)/Contents/Resources
	cp .build/release/$(APP) $(DEST)/Contents/MacOS/$(APP)
	cp Info.plist $(DEST)/Contents/Info.plist
	cp Icon/AppIcon.icns $(DEST)/Contents/Resources/AppIcon.icns
	codesign --force -s - $(DEST)
	touch $(DEST)
	open $(DEST)

uninstall:
	osascript -e 'quit app "$(APP)"' 2>/dev/null || true
	rm -rf $(DEST)

.PHONY: build install uninstall
