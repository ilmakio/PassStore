# Changelog

All notable changes to PassStore are documented here.

## [1.2.0] - Unreleased

### Added

- **Linked `.env` files.** When you import a `.env`, PassStore remembers where it came from.
  If that file later changes on disk, the item offers **Update from file**; **Write to file**
  sends your changes back out. Linked files are checked when you switch back to PassStore —
  nothing runs in the background, and nothing is written unless you ask. If the file and the
  item have both changed, PassStore says so and lets you choose which one wins. Writing edits
  the file in place — it replaces the values of the variables the item tracks and leaves your
  comments, blank lines, ordering and any variable PassStore does not know about exactly where
  they were, appending anything new at the end. Untick "Keep a link to this file" during import
  if you only want a one-off copy.
- **File → Import .env File… (⇧⌘O)** creates the item, fills in its keys and links the file in
  a single step. Also available from the command palette and the empty-vault screen.
- **Previous values.** When you change a secret, the value it replaced is kept, so you can look
  up or restore the password an item had before. Up to 10 versions per field, held in your
  encrypted vault and shown only when you ask for them. Old secrets stay recoverable until you
  remove them, so you can clear them for one item, clear them across the whole vault, or turn
  the feature off in Settings → Data.
- **Item history (⌘Y).** A window with the complete change log for an item and every previous
  value, each of which can be copied or put back. Reachable from the ⋯ menu in the detail pane
  and from an item's right-click menu.
- **Automatic Touch ID.** The unlock prompt now appears on its own when you open PassStore and
  when you switch back to it. Locking on purpose never triggers it; it returns once you have
  left the app and come back. Turn it off in Settings → General.
- **Restore a backup during setup.** The welcome screen offers "I already have a backup".
- **Erase the vault from Settings → Data**, for handing a Mac on or starting again from a
  backup — not only from the lock screen. Where Touch ID is set up it is now required before
  erasing, so nobody who walks past an unattended Mac can wipe your vault.
- **Start over after a forgotten master password.** A small link at the foot of the lock screen
  opens a page that lists exactly what will be deleted and what will be left alone, and asks
  you to type ERASE before it will do anything. There is still no way to recover a forgotten
  password — without it nothing can decrypt your secrets — but you are no longer stuck at a
  lock screen with no way forward.
- **About PassStore** now credits the author, states that the app is open source under the MIT
  licence, and links to the repository, the contributing guide and makio.app. The Help menu
  gained GitHub, Contribute, Report an Issue and website links.
- **Undo (⌘Z)** for restoring a backup, clearing previous values and restoring an old value.
- **Sort the item list** by name, last used, last modified or date created.
- **Copy without opening an item:** a copy button appears on hover in the list, ⇧⌘C copies the
  selected item's password, and the command palette can copy directly.
- **Lock and unlock from the menu bar.**
- **Duplicate a built-in template** to use it as a starting point, and reorder the fields of
  custom templates.
- **A Vault menu** gathering Lock, the password generator, Vault Health, item history and
  Update from linked file.

### Changed

- **⌘N creates a new secret item.** It used to open a second, empty window, and making an item
  was on ⇧⌘N — which now makes a new workspace.
- **⌘⌥P, "Open Main Window" and the Dock icon reuse the existing window** instead of opening
  another one each time, restoring it if it was minimised.
- **The menus were reorganised:** creating and importing under File, copying and Find under
  Edit, navigation and sorting under View, and everything vault-specific under Vault.
- **New shortcuts:** ⇧⌘C copy password, ⌘Y item history, ⌘R update from linked file.
- **"Recent" now lists the items you have actually opened**, plus anything you have just
  created. It previously showed the same items as "All Items", in a different order.
- **The yellow is a little deeper and warmer**, and filled buttons use a stronger shade of it
  with white labels. Some of them used to come out with black text and others white, because
  the label colour was picked automatically from a yellow too light to read white against.
- **The item editor was reorganised.** Name, workspace and type sit together, the workspace
  chooser shows each workspace's own icon and colour and can create a new one without leaving
  the menu, and "favourite" is a labelled checkbox rather than an unlabelled star. Environment
  moved in alongside the rest instead of occupying a section of its own.
- **Every screen shares one layout**, so Settings, the editors, import, export, Vault Health
  and bulk edit look and behave consistently. Settings gains a **Data** tab for previous
  values, linked files and recovery.
- **The list header no longer carries a description.** "Favorites" does not need "Pinned
  secrets you reach for often" written under it, and the strap line only pushed the list down.
- **PassStore follows your system text size**, and the sidebar now matches other Mac apps in
  row size and contrast.
- **The command palette ranks its results**, so typing part of a name brings that item to the
  top rather than burying it among tag matches.
- **Vault Health is harder to fool.** Common words, character sequences, keyboard patterns and
  repeated blocks now count as weak whatever their length — `password1234` used to pass.
- **Hidden secrets are masked at a fixed width**, so the mask no longer shows how long the
  secret is.

### Fixed

- **Restoring a backup no longer replaces your vault without asking.** A `.pstore` used to be
  applied the moment the password was accepted, discarding every workspace, item, template and
  preference with no summary and no way back. PassStore now shows what the backup contains and
  asks how to apply it: **Merge**, which adds what is missing and overwrites nothing, or
  **Replace**. Either way your current vault is copied aside first, so a restore can be undone
  with ⌘Z, or recovered later from Settings → Data even after quitting.
- **Restoring the same backup twice no longer duplicates every secret.**
- Backup merge now preserves custom templates, field metadata, timestamps, history, health
  dismissals and linked-file metadata. Conflicting copies and legacy exports are idempotent,
  and the complete merge is committed in one encrypted write.
- **Opening an item from the command palette shows it.** Picking an item that lived in another
  workspace closed the palette and left the detail pane empty.
- **The toolbar is empty while the vault is locked.** A stray sidebar toggle was left behind on
  the lock screen.
- **Active filters are shown above the list.** A type picked in the sidebar stayed on when you
  moved to another workspace or section, so the list could look mysteriously short with nothing
  explaining why. Filters now appear as a chip you can remove, with a Clear button.
- **The sort control tells the truth in Recent.** Recent is always ordered by last used, but
  the menu still offered — and appeared to apply — the other orders.
- **Secret values can be revealed from the keyboard.** Hovering still reveals and clicking
  still copies; sensitive fields now also have a reveal button, which keeps the value visible
  after the pointer moves away.
- **The item list behaves like a list:** ↑ and ↓ move through it, ⇧-click selects a range,
  ⌘-click adds or removes a single row, and Escape clears the selection. Arrow keys still stay
  out of the way of whatever you are typing in.
- **⌘-clicking a second item keeps the first one.** It used to drop whatever was already
  selected and start again from the row just clicked.
- **Unlocking, changing your master password and exporting no longer freeze the window.** All
  three now show real progress.
- **The password field is focused as soon as the lock screen appears**, and Return activates
  Unlock.
- **Browsing a large vault is much faster.** Selecting an item no longer rewrites the entire
  vault to disk.
- **Starring or archiving an item no longer counts as editing it**, so it does not jump to the
  top of Recent or reset how old Vault Health considers it.
- **Archiving keeps you where you were** instead of switching the sidebar to Archived.
- **Filtering by type stays inside the workspace you are viewing.**
- **`.env` files survive a round trip.** Key capitalisation is preserved, and values containing
  spaces, `#`, quotes or line breaks are quoted correctly instead of coming back wrong.
- **The `.env` parser handles real files:** quoted values, `export KEY=value`, values spanning
  several lines, and trailing comments.
- **Ordinary variables are no longer imported as secrets.** `MONKEY_COUNT` and
  `KEYBOARD_LAYOUT` used to be stored masked.
- **Duplicating an item twice gives each copy a distinct name.**
- Copying from the menu bar now shows the clipboard warning and updates the item's last-used
  time.
- Editing from the detail pane always edits the item you are looking at.
- Commands that need an unlocked vault are disabled while it is locked, instead of opening a
  window over the lock screen.
- Quitting immediately after opening an item keeps its last-used time.

### Security

- **The global ⌘⌥P shortcut no longer needs Accessibility permission.** PassStore previously
  had to be allowed to observe your keyboard system-wide; it now registers only that one
  shortcut. You can remove PassStore from System Settings → Privacy & Security → Accessibility.
- **The vault locks when your Mac sleeps, the screen locks or the screensaver starts.** Closing
  the lid used to leave it unlocked until the inactivity timer ran out.
- **The delay after failed password attempts survives quitting the app.**
- Restoring a backup re-checks Touch ID against this Mac rather than trusting the setting
  saved in the file.
- Lock, sleep and erase now invalidate in-flight unlock/import/export work and clear decrypted
  previews and undo state, so a late asynchronous result cannot reopen or repopulate a vault.
- Linked-file access now uses the app-scoped bookmark entitlement, renews stale bookmarks and
  refuses an unconfirmed overwrite if the file changed again.
- Generated `.env` output now quotes every value, escapes shell expansion/command substitution
  and repairs unsafe imported keys, so sourcing a linked or copied file cannot execute text
  smuggled into a field name, value or item title.
- Clipboard expiry now relies on the pasteboard ownership counter instead of retaining a hash
  of the copied secret in memory, while still leaving a newer clipboard value untouched.
- Sparkle now authenticates update archives before extracting any downloaded contents.
- Updated Sparkle from 2.9.1 to 2.9.5 and raised the package floor to the patched release.
- Updated swift-sodium from 0.10.0 to 0.11.0 (libsodium 1.0.22).

### Compatibility

- Vaults and `.pstore` backups written by 1.1.x open unchanged, and a vault written by 1.2.0
  stays readable by earlier versions.
- **The vault is now saved as a single file** rather than a key file plus a data file written
  one after the other. Interrupting the old two-file save — a crash or a flat battery at the
  wrong moment, particularly while changing your master password — could leave the two out of
  step and the vault unreadable. PassStore keeps the old pair up to date alongside it, so an
  earlier version still opens your vault.
- **The order of tags and environments in the sidebar moved inside the encrypted vault.** It
  used to sit in plain preferences, where the names of your tags were readable without
  unlocking anything. Your existing order is carried over on first unlock. If you later go
  back to an older version, that ordering resets to alphabetical — nothing else is affected.

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
