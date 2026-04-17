PROJECT    = Orbit.xcodeproj
CONFIG     = Debug
DERIVED    = .build
PRODUCTS   = $(DERIVED)/Build/Products/$(CONFIG)

APP        = $(PRODUCTS)/Orbit.app
HELPER     = $(PRODUCTS)/orbit-helper
MACOS      = $(APP)/Contents/MacOS

XCOPTS     = -project $(PROJECT) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

# ── Build ──────────────────────────────────────────────

.PHONY: build build-app build-helper clean run stop install log

build:
	xcodebuild $(XCOPTS) -scheme Orbit build | tail -5
	@xattr -rc $(DERIVED) 2>/dev/null || true

build-app:
	xcodebuild $(XCOPTS) -scheme Orbit build | tail -5

build-helper:
	xcodebuild $(XCOPTS) -scheme orbit-helper build | tail -5

# ── Run ────────────────────────────────────────────────

run: build stop
	@rm -f /tmp/orbit.sock
	@echo "── Starting Orbit.app ──"
	@"$(MACOS)/Orbit" 2>&1 &
	@sleep 1
	@echo "── Streaming [Orbit] logs (Ctrl-C to stop) ──"
	@/usr/bin/log stream --predicate 'process == "Orbit"' --style compact \
	  | grep --line-buffered "\[Orbit\]"

# ── Log (attach to running Orbit without restart) ─────

log:
	@echo "── Streaming [Orbit] logs (Ctrl-C to stop) ──"
	@/usr/bin/log stream --predicate 'process == "Orbit"' --style compact \
	  | grep --line-buffered "\[Orbit\]"

# ── Stop ───────────────────────────────────────────────

stop:
	@pkill -x Orbit 2>/dev/null || true
	@sleep 0.5

# ── Install hooks ──────────────────────────────────────

install: build
	"$(HELPER)" install

# ── Clean ──────────────────────────────────────────────

clean:
	xcodebuild $(XCOPTS) -scheme Orbit clean | tail -3
	@rm -f /tmp/orbit.sock
