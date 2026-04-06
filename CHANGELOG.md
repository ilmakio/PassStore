# Changelog

All notable changes to PassStore are documented here.

## [1.0.2] - 2026-04-06

### Added
- First-launch onboarding flow to guide you through setting your master password, enabling Touch ID, and creating your first workspace
- Multi-select support in lists: copy multiple items as .env, delete, duplicate, and manage entries faster

### Improved
- .pstore backup export/import now includes all preferences (workspaces, tags, passwords, and more)

## [1.0.1] - 2026-04-04

### Fixed
- Bug fixes and stability improvements
- UI refinements

## [1.0.0] - 2026-04-03

### Added
- Initial release
- Workspace-based secret organization
- Support for multiple secret types: Generic, .env Group, Database, API Credential, MinIO/S3, Server/SSH, Website/Service
- Custom templates with configurable field types
- AES-256-GCM encryption with Argon2id key derivation
- macOS Keychain integration for secure key storage
- Touch ID biometric unlock
- Encrypted .pstore backup export/import
- .env file import
- Command palette with global keyboard shortcut
- Menu bar quick access panel
- Clipboard auto-clear
- Auto-lock with configurable timeout
- Search and filtering by title, tags, fields, and environment
- Copy as .env, JSON, or database connection string
