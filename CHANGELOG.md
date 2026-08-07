# Changelog

All notable changes to PassStore are documented here.

## [1.1.0] - 2026-08-07

### Added

- **Change your master password**, from Settings → Master Password. This was previously impossible: the capability existed internally but was not reachable anywhere in the app. Changing it re-wraps the vault key, so none of your data is re-encrypted and Touch ID keeps working. Your current password is required.
- **Vault Health** (⌘K → "Check Vault Health") finds secrets reused across several items, weak secrets, and items you have not touched in a year. The report only ever shows item titles and field labels — never a secret value.
- **A real password generator** (⇧⌘G, or the wand button on any secret field): choose the length, pick which character classes to use, and optionally avoid look-alike characters such as 0/O and 1/l/I. Generated passwords always contain at least one character from every class you enabled.
- **Workspace management from the sidebar.** Right-click any workspace to edit it, add an item to it, or delete it. Deleting a workspace keeps its items and simply unassigns them.
- Remove fields you no longer need, and reorder them, in both the item editor and custom templates. Previously fields could only be added.
- Open URL fields directly in your browser.
- Item details now show when a secret was created, last modified, and last used.
- Keyboard navigation: ⌘F jumps to the search field, ⌥↑ and ⌥↓ move through the item list.
- Item counts beside each sidebar section and workspace.

### Fixed

- **Deleting a secret now always asks for confirmation.** Right-clicking an item and choosing Delete, or "Delete N Items" on a multi-selection, previously destroyed secrets instantly, with no confirmation and no way back.
- **Fixed a crash when saving an item whose fields ended up sharing a storage key** — for example after renaming a field so its key matched an existing one. Both fields are now kept.
- Hardened backup import against malformed files that repeat a workspace or template id.
- "Open Main Window" in the menu bar now works after you have closed the main window.
- Primary buttons in sheets used black text on the accent colour and were hard to read; they now use white.
- "Select All" in the selection bar now reflects the items actually on screen after a search or filter change.
- Copying several items as JSON no longer drops one when two items share a title.
- Archiving a multi-item selection no longer reloads the vault once per item.

### Improved

- **Search now matches field values, not just field labels**, so you can find an item by the host or username it contains. Every word you type has to match, which narrows results instead of widening them. Sensitive values are deliberately excluded, so the search box can never be used to confirm a secret's contents.
- The item editor is much calmer: field rows show the field name and its value, with label, storage key, kind and sensitivity moved behind the Advanced toggle.
- Empty states now tell a brand-new vault apart from an over-filtered list, and offer a useful action in each case.
- Press Return to move through the onboarding password and workspace steps.
- Export and import backup sheets no longer clip their buttons.
- Creating an item with staged `.env` text no longer re-parses it on every keystroke.

## [1.0.4] - 2026-04-07

Official public release

## [1.0.3] - 2026-04-07

### Fixed
- Updated automated export/import coverage to match the v3 `.pstore` backup API
- Resolved a Swift concurrency warning in the global command palette hotkey monitor

### Changed
- Added an unsigned Xcode verification lane for CLI and CI checks
- Polished the public GitHub issue template and funding metadata ahead of the open source launch

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
