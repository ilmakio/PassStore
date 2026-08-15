# Changelog

All notable changes to PassStore are documented here.

## [1.2.0] - Unreleased

### Added

- **Linked `.env` files.** An item can now remember the file it was imported from. When that
  file changes on disk, the item shows **Update from file** — one click instead of find,
  open, copy, paste, save. **Write to file** pushes the other way. PassStore checks linked
  files when its window comes to the front; nothing runs in the background and nothing is
  written without you asking. If both sides changed, it says so and lets you pick.
- **Previous values.** Rotating a secret now keeps the value it replaced, so you can look up
  or restore the password an item had before. Up to 10 versions per field, inside the same
  encrypted vault, revealed only on request. This is a real trade-off — an old secret stays
  recoverable until you delete it — so it can be purged per item, purged across the whole
  vault, or switched off entirely in Settings → Data.
- **Automatic Touch ID.** The unlock prompt now appears by itself when PassStore launches and
  when you switch back to it, so unlocking takes no clicks at all. Locking on purpose never
  triggers it — that would undo the thing you just asked for — so the prompt only returns
  once you have left the app and come back. Turn it off in Settings → General.
- **Restore from a backup during setup.** The welcome screen now has an "I already have a
  backup" path, instead of leaving a new arrival to find the import command in a menu.
- **A way out of a forgotten master password.** The lock screen now offers to erase the vault
  and start over. There is still no recovery — that is the design — but being permanently
  stuck at a lock screen with no option but deleting files by hand was not a design.
- **Undo (⌘Z)** for destructive vault actions: restoring a backup, purging history, restoring
  an old value.
- **Sort the item list** by name, last used, last modified or date created.
- **Full item history** in its own window, with the complete change log and every stored
  previous value.
- **Duplicate a built-in template.** Built-ins are read-only, and there was previously no way
  to start from one — adding a field to "Database" meant rebuilding it from scratch.
- **Reorder template fields.** The item editor got this in 1.1.0; the template editor did not.
- Quick copy straight from the item list on hover, and from the command palette.
- Unlock and lock from the menu bar.

### Fixed

- **Restoring a backup no longer replaces your vault without asking.** A `.pstore` used to be
  applied the instant the password was accepted: every workspace, item, template and
  preference gone, with no summary, no confirmation and no way back. PassStore now shows what
  the backup contains and asks how to apply it — **Merge** (the default; adds what is missing
  and overwrites nothing) or **Replace**. Either way it copies your current vault aside first,
  so the restore is reversible with ⌘Z and still recoverable after quitting, from
  Settings → Data.
- **Restoring a backup no longer duplicates everything on a second import.** Item ids were
  discarded on restore, so re-importing the same file made a second copy of every secret.
- **Secret values can be revealed from the keyboard.** Hovering a secret still shows it and
  clicking still copies it, exactly as before — but that was the *only* way, so keyboard and
  VoiceOver users could not read a stored secret at all. Every sensitive field now also has a
  reveal button, which keeps the value shown after the pointer moves away.
- **The item list is a real list.** Arrow keys, ⇧-click ranges and ⌘-click toggling all work,
  and the list takes focus properly.
- **Selecting an item no longer re-encrypts and rewrites the entire vault.** The "last used"
  stamp triggered a full synchronous save on every single click — and on every keypress when
  walking the list. Writes are now coalesced.
- **Unlocking, changing your master password and exporting no longer freeze the window.** Key
  derivation ran on the main thread, and because it was synchronous the progress indicator
  never got a chance to appear. All three now run off the main thread and show real progress.
- **The password field on the lock screen takes focus.** Every unlock used to start with a
  mouse click. The default button and the prominent button are also the same button now;
  pressing Return previously did something other than what the UI implied.
- **Starring or archiving an item no longer counts as editing it.** Both bumped the modified
  date, which pushed the item to the top of "Recent" and reset the staleness clock the health
  audit reads — so un-starring and re-starring silently cleared a warning.
- **Archiving no longer throws you out of the workspace you were in.** The sidebar stayed put
  and the confirmation appears under the list instead.
- **The type filter stays inside the workspace you are looking at.** It used to widen to the
  whole vault while the header still named the workspace.
- **"Recent" means recently opened.** It used to show exactly the same items as "All Items",
  with the same badge count, only sorted differently.
- **`.env` round-trips no longer corrupt values.** Keys were upper-cased on the way out, so
  `Api_Key` came back as `API_KEY` — a different variable. Values containing spaces, `#`,
  quotes or newlines were written unquoted and came back wrong or truncated.
- **The `.env` parser now handles real files:** quoted values keep their content and lose
  their quotes, `export KEY=value` is understood, values may span several quoted lines, and a
  trailing comment is not part of the value.
- **Ordinary variables are no longer imported as secrets.** Any name containing the letters
  "key" was treated as sensitive, so `MONKEY_COUNT` and `KEYBOARD_LAYOUT` were stored masked.
- **Vault Health is harder to fool.** `password1234` scored "Fair" and was never reported.
  Common base words, character runs, keyboard patterns and repeated blocks are now weak
  whatever their length.
- **Duplicating an item twice produces distinct titles** instead of two items called
  "X Copy".
- Copying from the menu bar now shows the first-time clipboard warning and records the item as
  used, so the menu bar's own most-recently-used ordering actually moves.
- Editing an item from the detail pane edits that item, rather than whatever happened to be
  selected at the time.
- Hidden secrets are masked at a fixed width; the mask used to publish the exact length of
  every secret on screen.

### Security

- **The global ⌘⌥P shortcut no longer needs Accessibility permission.** PassStore used to
  install a global keyboard monitor, which meant it received every keystroke typed in every
  application — a keylogger-shaped permission for a password manager. It now registers that
  one chord with the system and sees nothing else.
- **The vault locks when your Mac sleeps, the screen locks or the screensaver starts.** Closing
  the lid previously left the vault unlocked in memory until the inactivity timer happened to
  fire.
- **The failed-attempt delay survives a relaunch.** It was held in memory, so quitting the app
  reset it.
- Restoring a backup that says "biometrics enabled" now re-checks this Mac's Keychain instead
  of trusting the setting.

### Improved

- **Every screen is built from one set of components.** Settings, the template editor, item
  creation and editing, export, import, vault health and bulk edit each rolled their own
  header, footer, spacing and card chrome — which is why some clipped their buttons and no two
  looked quite alike. Settings gains a **Data** tab for history, linked files and recovery.
- **The app follows your system text size.** Font sizes were hard-coded in points throughout,
  including in the sidebar.
- **The sidebar looks like a macOS sidebar** — standard row height, full label colour, proper
  icon size. It previously rendered at 11pt in a secondary grey, which made every row look
  disabled.
- **The command palette ranks results.** An item matching on an obscure tag used to rank
  exactly as high as one whose name you had typed in full. It also stops rebuilding the entire
  entry list on every keystroke.
- Long secrets get soft line breaks every 24 characters rather than between every single
  character, which was slow on long keys and made VoiceOver read them letter by letter.
- Small text no longer uses the tertiary colour, which failed contrast at that size.

## [1.1.1] - 2026-08-16

### Added

- **Item history.** Every secret now keeps an audit trail of what happened to it — created, renamed, field added or removed, secret changed, password rotated, archived, restored, moved between workspaces. It appears in a History section in the detail pane. Entries record the *kind* of change and at most a field label: a secret value is never written to the trail.
- **Dismiss a vault health finding.** Each finding in Vault Health now has an ignore button. A dismissal is tied to the exact value that caused it, so silencing a weak password hides today's warning and not tomorrow's — change the secret and the finding comes back on its own. Dismissed findings are listed separately and can be restored individually or all at once.
- **Bulk edit.** Select several items and choose "Edit…" to add or remove tags, move them to a workspace, set their environment, or change favourite and archive status in one pass. Every option defaults to "keep", so only what you explicitly change is applied.
- **Master password history.** Settings → Master Password now shows when the master password was last changed, with the full history of changes. It is stored inside the encrypted vault payload, not in the plaintext metadata file.

### Improved

- **Staleness is now measured from the password's own rotation date**, not from the last time the item was edited. Renaming an item no longer makes a two-year-old credential look freshly reviewed. Items with no recorded rotation still fall back to the previous behaviour.
- **Item drafts are cleaned at the repository boundary**, so the same rules apply whether an item comes from the editor, a bulk edit, a `.env` import or a restored backup: titles and field labels are trimmed, tags are de-duplicated case-insensitively, and a blank custom environment falls back to a preset. Field values are deliberately left untouched — trimming a stored secret would corrupt it.
- Tags containing a comma no longer split into two tags the next time the vault is loaded.

### Compatibility

- Vaults written by 1.1.0 and earlier open unchanged; the new fields default to empty. A vault written by 1.1.1 stays readable by 1.1.0, which simply ignores what it does not know.

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
