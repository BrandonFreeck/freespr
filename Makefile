# freespr — build + install. `make install` then `freespr init`.
BINARY      := freespr
PREFIX      ?= $(HOME)/.local/bin
APP_DEST    := $(HOME)/Applications/freespr.app
APP_BIN     := $(APP_DEST)/Contents/MacOS/$(BINARY)
CONFIG_DIR  := $(HOME)/.config/freespr
RELEASE     := .build/release/$(BINARY)
CODESIGN_ID := com.freespr.agent
# One version source: freesprVersion in Sources/freespr/CLI.swift. `install` stamps it into Info.plist.
VERSION     := $(shell sed -n 's/^let freesprVersion = "\(.*\)"$$/\1/p' Sources/freespr/CLI.swift)

# Signing identity for freespr.app. Auto-detect the stable self-signed cert if `make cert` has been
# run (→ TCC grants persist across reinstalls); otherwise ad-hoc (`-`, re-grant each reinstall).
# Override with `make install CODESIGN=-` to force ad-hoc.
CODESIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q 'freespr-codesign' && echo freespr-codesign || echo -)

.PHONY: build check glow-check test install reinstall stop reload path-check uninstall clean cert

build:
	swift build -c release

# Offline self-checks (ToneStrip + Config + WAV header). No permissions, no network.
check: build
	$(RELEASE) config --check

# Live-desktop glow regression: strands the indicator's windows on another Space (how macOS 26 left
# them on 2026-10-14) and asserts the glow still lands on screen. Not in `check`: needs a GUI session.
glow-check:
	@mkdir -p .build/glow-check
	swiftc -swift-version 5 -O Sources/freespr/Indicator.swift scripts/glow-check/main.swift -o .build/glow-check/glow-check
	.build/glow-check/glow-check

# Live end-to-end: speak a known fixture with `say` and run the REAL pipeline (transcription, then
# cleanup, both on OpenAI, so it costs a little on your key). Asserts the vocab-biased term survives.
# Hermetic: it reads this folder's vocab.txt, style.md and config.toml through a scratch home
# (CFFIXED_USER_HOME), never your ~/.config/freespr, and it never touches the clipboard.
# No mic, hotkey or Accessibility needed; just the key: OPENAI_API_KEY if set, else the Keychain item.
test: build
	@t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
	mkdir -p "$$t/.config/freespr" && cp vocab.txt style.md config.toml "$$t/.config/freespr/" && \
	say "Ship the vLLM benchmark on Kubernetes before Friday." -o "$$t/fx.aiff" && \
	afconvert -f WAVE -d LEI16@16000 -c 1 "$$t/fx.aiff" "$$t/fx.wav" || exit 1; \
	k="$$OPENAI_API_KEY"; [ -n "$$k" ] || k=$$(security find-generic-password -s freespr -a openai-api-key -w 2>/dev/null); \
	[ -n "$$k" ] || { echo "FAIL: no OpenAI key (set OPENAI_API_KEY or run 'freespr init')"; exit 1; }; \
	echo "=== freespr test-pipeline (real transcription + cleanup) ==="; \
	out=$$(CFFIXED_USER_HOME="$$t" OPENAI_API_KEY="$$k" $(RELEASE) test-pipeline "$$t/fx.wav") || { echo "$$out"; exit 1; }; \
	echo "--- output ---"; echo "$$out"; echo "--------------"; \
	fail=0; \
	echo "$$out" | grep -qi 'vLLM'       && echo "  ok   vLLM (vocab bias)" || { echo "  FAIL vLLM missing";      fail=1; }; \
	echo "$$out" | grep -qi 'benchmark'  && echo "  ok   benchmark"         || { echo "  FAIL benchmark missing"; fail=1; }; \
	echo "$$out" | grep -qi 'Kubernetes' && echo "  ok   Kubernetes"        || echo "  warn Kubernetes not found (soft)"; \
	[ $$fail -eq 0 ] && echo "PASS: pipeline E2E" || { echo "FAIL: pipeline E2E"; exit 1; }

# One-time: create the stable self-signed code-signing identity (idempotent). Run this when you want
# Accessibility/Mic grants to persist across reinstalls; afterwards `make install` auto-uses it.
cert:
	@sh scripts/freespr-cert.sh

install: build
	# Assemble freespr.app. A real bundle id (packaging/Info.plist) + AssociatedBundleIdentifiers in
	# the LaunchAgent plist (written by `freespr init`) is what lets the HEADLESS launchd agent hold
	# its TCC grants as the bundle (Accessibility, Microphone). Resources stay in ~/.config/freespr.
	@[ -n "$(VERSION)" ] || { echo "ERROR: could not read freesprVersion from Sources/freespr/CLI.swift"; exit 1; }
	@rm -rf "$(APP_DEST)"
	@mkdir -p "$(APP_DEST)/Contents/MacOS"
	cp "$(RELEASE)" "$(APP_BIN)"
	cp packaging/Info.plist "$(APP_DEST)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(VERSION)" "$(APP_DEST)/Contents/Info.plist"
	codesign --force --sign $(CODESIGN) --identifier $(CODESIGN_ID) "$(APP_DEST)"
	@if [ "$(CODESIGN)" = "-" ]; then echo "  signed ad-hoc — re-grant Accessibility each reinstall (run 'make cert' for persistence)"; else echo "  signed with '$(CODESIGN)' — grants persist across reinstalls"; fi
	# CLI symlink → the in-bundle binary (must be the same signed Mach-O the daemon runs).
	@mkdir -p "$(PREFIX)"
	ln -sf "$(APP_BIN)" "$(PREFIX)/$(BINARY)"
	@mkdir -p "$(CONFIG_DIR)"
	@for f in vocab.txt style.md config.toml; do \
		if [ ! -f "$(CONFIG_DIR)/$$f" ]; then cp "$$f" "$(CONFIG_DIR)/$$f"; echo "  installed $$f -> $(CONFIG_DIR)/$$f"; fi; \
	done
	@$(MAKE) --no-print-directory path-check
	@echo ""
	@echo "Installed freespr.app -> $(APP_DEST)"
	@echo "Next:  freespr init"

# The daemon uses the absolute path so it's unaffected by PATH. This only fixes the
# interactive `freespr` command when PREFIX isn't on PATH.
path-check:
	@if ! command -v $(BINARY) >/dev/null 2>&1; then \
		if [ -w /usr/local/bin ]; then \
			ln -sf "$(PREFIX)/$(BINARY)" /usr/local/bin/$(BINARY); \
			echo "  symlinked -> /usr/local/bin/$(BINARY) (on PATH)"; \
		else \
			echo ""; \
			echo "  NOTE: $(PREFIX) is not on your PATH. Add it with:"; \
			echo "    echo 'export PATH=\"\$$HOME/.local/bin:\$$PATH\"' >> ~/.zshrc && exec zsh"; \
		fi; \
	fi

# Iterate loop: stop the agent FIRST, wipe build, recompile fresh, reinstall, restart.
# Order matters — `install` does cp + codesign on the installed binary, which is the exact file
# the running daemon is executing; mutating it live can ETXTBSY/kill the process or trip a
# code-signing violation. So `stop` (bootout) precedes install. Default for every code change.
reinstall: clean stop install reload

# Stop the running agent so its binary can be safely replaced. Boot it out of launchd, then make
# sure no stray process survived (bootout misses anything launchd isn't tracking) — escalate to
# SIGKILL if it's still alive, so the old version is provably dead before we install the new one.
stop:
	@uid=$$(id -u); \
	launchctl bootout gui/$$uid/com.freespr.agent 2>/dev/null || true; \
	pkill -f '$(BINARY) run' 2>/dev/null || true; \
	sleep 1; \
	if pgrep -f '$(BINARY) run' >/dev/null 2>&1; then \
		echo "  old agent still alive — force-killing"; pkill -9 -f '$(BINARY) run' 2>/dev/null || true; sleep 1; \
	fi; \
	if pgrep -f '$(BINARY) run' >/dev/null 2>&1; then echo "  WARN: a freespr process is STILL running"; else echo "  old agent stopped (none running)"; fi

# Start (or restart) the background agent with whatever binary is currently installed. `install`
# alone does NOT do this — the old agent keeps running old code until it's bounced.
# bootout returns before launchd has let go of the label, and bootstrapping too soon fails with
# "Bootstrap failed: 5". So: wait for the old job to be gone, retry bootstrap once, and
# fail loudly (exit 1) unless a live pid comes back.
reload:
	@uid=$$(id -u); svc=gui/$$uid/com.freespr.agent; \
	plist="$(HOME)/Library/LaunchAgents/com.freespr.agent.plist"; \
	launchctl bootout $$svc 2>/dev/null || true; \
	if [ ! -f "$$plist" ]; then echo "  (no LaunchAgent yet — run 'freespr init' once to set it up)"; exit 0; fi; \
	i=0; while launchctl print $$svc >/dev/null 2>&1 && [ $$i -lt 20 ]; do sleep 0.5; i=$$((i+1)); done; \
	launchctl enable $$svc 2>/dev/null || true; \
	if ! launchctl bootstrap gui/$$uid "$$plist" 2>/dev/null; then \
		sleep 2; \
		launchctl bootstrap gui/$$uid "$$plist" || { echo "  ERROR: launchctl bootstrap failed twice; the agent is NOT running. Run 'make reload' again."; exit 1; }; \
	fi; \
	launchctl kickstart -k $$svc; \
	sleep 1; \
	pid=$$(launchctl print $$svc 2>/dev/null | awk '/pid =/{print $$3; exit}'); \
	if [ -z "$$pid" ]; then echo "  ERROR: the agent is loaded but not running. launchd says:"; launchctl print $$svc 2>&1 | sed -n '1,20p'; exit 1; fi; \
	echo "  agent reloaded — running fresh as pid $$pid"

# `freespr uninstall` asks before purging; yes (or --purge) removes everything freespr installed. The
# leftovers below go only if they're ours: a CLI link only when its whole chain ends at this
# account's $(APP_BIN), and the app folder only when its bundle id is $(CODESIGN_ID). Everything is
# decided BEFORE anything runs or is deleted: the purge removes the app, and a chained link only
# resolves while the link it passes through still exists.
uninstall:
	@ours=no; [ "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(APP_DEST)/Contents/Info.plist" 2>/dev/null)" = "$(CODESIGN_ID)" ] && ours=yes; \
	a=$$(readlink -f "$(APP_BIN)" 2>/dev/null); \
	l1="$(PREFIX)/$(BINARY)"; l2=/usr/local/bin/$(BINARY); k1=no; k2=no; \
	[ -L "$$l1" ] && [ -n "$$a" ] && [ "$$(readlink -f "$$l1" 2>/dev/null)" = "$$a" ] && k1=yes; \
	[ -L "$$l2" ] && [ -n "$$a" ] && [ "$$(readlink -f "$$l2" 2>/dev/null)" = "$$a" ] && k2=yes; \
	if [ "$$ours" = yes ] && [ -x "$(APP_BIN)" ]; then "$(APP_BIN)" uninstall || true; fi; \
	for pair in "$$k1:$$l1" "$$k2:$$l2"; do \
		k=$${pair%%:*}; l=$${pair#*:}; \
		if [ "$$k" = yes ]; then [ -L "$$l" ] && rm -f "$$l" && echo "  removed CLI link $$l"; \
		elif [ -L "$$l" ] || [ -e "$$l" ]; then echo "  skipped $$l (it doesn't lead to $(APP_BIN))"; fi; \
	done; \
	if [ -d "$(APP_DEST)" ]; then \
		if [ "$$ours" = yes ]; then rm -rf "$(APP_DEST)" && echo "  removed $(APP_DEST)"; \
		else echo "  skipped $(APP_DEST) (its bundle id isn't $(CODESIGN_ID))"; fi; \
	fi; \
	echo "Config, key, grants and log stay unless you answered yes or used --purge."

clean:
	swift package clean
	rm -rf .build
