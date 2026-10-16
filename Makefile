APP := dist/AgentBar.app
BIN := .build/release/AgentBar
CODESIGN_ID ?= AgentBar Dev

ZIP := dist/AgentBar.zip

.PHONY: app install zip clean test

test:
	swift test

SRC := $(shell find Sources -name '*.swift') Package.swift

$(BIN): $(SRC)
	swift build -c release

app: $(BIN)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN) $(APP)/Contents/MacOS/AgentBar
	mkdir -p $(APP)/Contents/Resources
	cp Packaging/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	@if security find-identity -v -p codesigning | grep -q "$(CODESIGN_ID)"; then \
		codesign --force --sign "$(CODESIGN_ID)" $(APP); \
		echo "Signed with '$(CODESIGN_ID)'"; \
	else \
		echo "warning: identity '$(CODESIGN_ID)' not found — ad-hoc signing." ; \
		echo "         run Packaging/make-signing-cert.sh once to stop keychain re-prompts."; \
		codesign --force --sign - $(APP); \
	fi
	@echo "Built $(APP)"

install: app
	rm -rf /Applications/AgentBar.app
	cp -R $(APP) /Applications/AgentBar.app
	@echo "Installed /Applications/AgentBar.app"

zip: app
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Created $(ZIP)"
	@echo "Receiver: move AgentBar.app to /Applications, then approve it once in"
	@echo "System Settings > Privacy & Security ('Open Anyway')."

clean:
	rm -rf .build dist
