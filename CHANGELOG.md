# Changelog

All notable changes to Orbit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0.0] - 2026-04-07

### Added
- New `stage-orbit-helper.sh` script for local development workflow
- Enhanced onboarding flow with better state management and auto-repair
- Conflict monitoring improvements for detecting configuration drift
- Support for additional hook events (PreCompact, Elicitation, ElicitationResult)
- Better session lifecycle tracking with token statistics

### Changed
- Improved installer with idempotent operations and force-install mode
- Enhanced socket server with better error handling and response modes
- Refactored CLI to support new hook response types (PermissionRequest, Elicitation)
- Better state management for session transitions and history
- Improved UI components with accessibility enhancements
- Updated i18n support with expanded locale coverage

### Fixed
- Statusline wrapper now handles edge cases with non-standard configurations
- Installer properly detects and repairs orphaned wrapper scripts
- Session token tracking maintains independent totals per session
- Race conditions in file-based state management resolved

