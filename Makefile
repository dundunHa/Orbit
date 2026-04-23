# Makefile for Orbit Project
# Frontend: JavaScript/TypeScript | Backend: Rust (Tauri)

.PHONY: help fmt ffmt debug-ui

PYTHON ?= python3
DEBUG_PORT ?= 6666

# Default target
help:
	@echo "Available targets:"
	@echo "  make ffmt - Format frontend code (Prettier + ESLint fix)"
	@echo "  make fmt  - Format backend code (rustfmt + Clippy fix)"
	@echo "  make debug-ui - Serve browser debug UI on localhost"

# Backend formatting (rustfmt + Clippy fix + warn check)
fmt:
	@echo "→ Formatting backend code..."
	cd src-tauri && cargo fmt
	@cd src-tauri && cargo clippy --all-targets --all-features --fix --allow-staged 2>/dev/null || true
	@echo "→ Checking for remaining warnings..."
	cd src-tauri && cargo clippy --all-targets --all-features -- -D warnings
	@echo "✓ Backend formatting complete"

# Frontend formatting (Prettier + ESLint fix)
ffmt:
	@echo "→ Formatting frontend code..."
	@if command -v prettier >/dev/null 2>&1; then \
		prettier --write "src/**/*.{js,jsx,ts,tsx,json,css,md}" 2>/dev/null || true; \
	else \
		npx prettier --write "src/**/*.{js,jsx,ts,tsx,json,css,md}" 2>/dev/null || true; \
	fi
	@if [ -f "package.json" ]; then \
		npm run lint:fix 2>/dev/null || npm run lint -- --fix 2>/dev/null || true; \
	fi
	@echo "✓ Frontend formatting complete"

# Browser-only frontend debugging with a mocked Tauri bridge.
debug-ui:
	$(PYTHON) scripts/debug-ui-server.py --port $(DEBUG_PORT)
