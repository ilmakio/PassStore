# Changelog

All notable changes to PassStore are documented here.

## [1.3.0] - 2026-08-19

### Added

- **Environments belong to a workspace.** A workspace can state which environments its project
  has — Local, Dev, Staging, Prod or names of your own — in which order they are offered and
  which of them are still current. An environment can be switched off without deleting
  anything, and one that still holds secrets stays reachable. Environments your secrets already
  use but the project never declared are listed alongside the declared ones, so an existing
  vault shows its structure without anything to migrate. Renaming a declaration moves the
  secrets that were in it, in one step.
- **Enter a workspace one environment at a time.** A project with `.env.local`,
  `.env.staging` and `.env.production` stops being three unrelated rows in one long list.
  Workspaces expand in the sidebar into their environments, the item list gains a row of tabs
  with counts, and **⌘⌥←** / **⌘⌥→** move along them — "All" included. A new secret inherits
  the environment you are standing in, or the first one the project offers. A workspace with
  nothing to divide gets no triangle and no tabs, so vaults that do not use environments look
  and behave exactly as before.
- **A page for each workspace.** Standing in a workspace with nothing selected used to spend
  the whole detail pane asking for a click. It now describes the project: its name over a band
  in its own colour, how many secrets it holds and how they are spread across its environments,
  how many mirror a file on disk and whether any have drifted, and one button to add the next
  secret. Everything you can do *to* the workspace — edit it, link a folder, delete it — is in
  one menu instead of three buttons that each looked like the main event.
- **Point a workspace at the folder its project lives in.** PassStore then lists the `.env`
  files inside it and imports the ones you tick: one secret per file, each linked to the file it
  came from and each landing in the environment its name implies. Nothing is scanned at unlock
  or on a timer — a scan happens when you ask for one — and `.env.example` and friends are
  listed but never pre-selected. Unlinking hands the folder permission back in one click.
- **New Workspace from Folder… (⇧⌘N)** builds the whole workspace from a repository: it takes
  the folder's name, proposes an environment for every `.env` it finds, and lets you drop the
  ones you do not want before anything is created. A repository already knows its own name, and
  the files next to its code already say which environments it has.
- **Compare keys across a workspace's environments.** Answers the two questions a project with
  several `.env` files keeps raising: what is production missing, and am I using the same secret
  in more than one place. The workspace page states the finding in a sentence — "Staging is
  missing 3 keys" — and clicking it opens the grid. An empty value and an absent key are drawn
  differently, because in a `.env` the first is a decision and the second an omission. Two
  secrets defining the same key in one environment are flagged: they can disagree, and
  something is ignoring one of them.
- **Resolve a linked `.env` one variable at a time.** The link now records a digest of each
  variable's value at every sync, which is what makes it possible to say *which side moved* for
  a given variable rather than only for the file. The entry that differs is marked in the detail
  pane and offers to take the file's value or to write its own — either way touching that one
  variable and nothing else. A variable the file sets and the secret does not is listed, where
  it can be added.
- **A `.env` keeps its comments.** An imported `.env` used to have every comment flattened into
  one notes block, so the note explaining a variable ended up several screens away from it. A
  secret now remembers the shape of the file it came from — comments, blank lines, ordering,
  indentation, `export` prefixes, quoting, values written across several lines — and no values
  at all: a value lives only in its field, so the layout can never become a stale second copy of
  a secret. The detail pane reads those comments the way the file does: banner blocks become
  headings, a block above a run of variables introduces that run, and a `# note` after a value
  sits under that value.
- **Copy as .env (⇧⌘E) reproduces the file you imported**, comments and all.
  **Copy as .env (Values Only) (⇧⌥⌘E)** keeps the plain keys-and-values form for anything that
  strips comments anyway. Rendering needs no access to the file, so it works from a backup and
  on another Mac.
- **Copy to Environment and Move to Environment**, on one secret or on a whole selection, so
  "take this to production" and "give production one of its own" stop being done by hand.
- **A secret's siblings are in its header.** Where the same secret exists in more than one
  environment of a project, the others are listed under its name and are one click away — with
  a `+` to create the one that is missing.
- **Name a field and press Return.** The new-secret sheet has a row for adding a field that is
  always visible: type a name, press Return, and the cursor lands in that field's value. Return
  there comes back for the next one, so a set of variables can be typed straight through without
  touching the mouse.
- **The empty detail pane offers the thing it talks about.** It said "or create a new one" while
  having no button to do it; now it has one, and says ⌘N does the same.
- **Setup says how far along you are.** The onboarding steps are named — Welcome, Password,
  Touch ID, Workspace, Done — with the one you are on picked out and the ones behind you ticked.

### Changed

- **Creating a secret is one page.** It used to open on a full screen of template cards, so the
  kind of thing you were storing had to be decided before you were allowed to type its name —
  and a custom template was reachable *only* from that page. Now the sheet opens on the form:
  three pickers across the top for **workspace, environment and type**, because those decide
  where the secret will be when you go looking for it, and the name underneath. The type picker
  lists every template, custom ones included, and changing it fills the fields in without
  discarding anything you have already typed.
- **The new-secret sheet is painted in the workspace's colour**, carries its icon, and says
  where the secret will land — `Pokéos API · Staging · Database` — under the title. Opening it
  from inside a workspace already filed the secret there; now the sheet looks like it.
- **The environment picker offers the environments the workspace actually has.** It was a
  segmented control over five fixed presets, which is not what a project with "Local, Staging
  EU, Prod" has — so filing a secret in one of its own environments meant choosing "Custom" and
  retyping the name, exactly right, from memory.
- **There is no "Advanced" switch in the item editor.** It lived in the section header and
  applied to every field at once: turning it on to rename one field unfolded a label box, a
  storage-key box, a kind popup and three checkboxes under *all* of them, and the form doubled
  in height. Renaming, reordering, the value kind and the sensitive / masked / copyable flags are
  now in a menu on the field they belong to.
- **Setting a field's kind to Secret makes it sensitive and masked.** Calling a value "Secret"
  and leaving it neither contradicts itself. Deliberately one-way: switching back to Text leaves
  the flags alone rather than quietly unmasking a value that is already stored.
- **Tags and notes share one card**, with a rule between them, instead of taking a titled
  section each — two optional afterthoughts had the same weight as the fields.
- **One yellow.** The app had drifted into four: the asset accent, the system accent, the system
  yellow and a readable gold, mixed almost at random. There is now a single rule — the brand
  yellow is what gets *painted*, always with black content on it, and a deeper shade of the same
  hue is used wherever the accent is the ink instead. Section rules, chips, glyphs, badges,
  selection washes and the password-strength meter all follow it.
- **Notices come in two registers, not five.** A pane could hold a green sentence, an amber one,
  a grey one and a yellow one, none of which meant anything by being that colour, each with a
  decorative `(i)` in front of it. Now: something needs you — a tinted band, a coloured glyph and
  readable text — or it does not, in which case it is one quiet grey line with no icon at all.
  "Everything matched at the last check" no longer shouts in green.
- **Every button in the app is the app's button.** Inline actions, small buttons beside a text
  field, "Update from File", "Write to File", "Link a .env File…", the add-field and add-tag
  buttons and the text links inside a sentence were a mix of stock macOS styles. They now share
  one shape in three sizes. The text links in particular were drawn in the app's tint — bright
  yellow, at caption size, on a white sheet.
- **Icons that identify something are a solid tile with a contrasting glyph** — the treatment the
  item detail already had — in sheet headers, on the workspace page, on the template cards and in
  the workspace previews. The washed 15%-tint version made the one element meant to carry the
  colour the palest thing on the screen.
- **A list row names where its secret lives on the right-hand edge**, as plain text with the
  colour on the glyph only, instead of a capsule in the middle of the row competing with the
  secret's own name. The type's icon sits tight against its name rather than a menu-row's width
  away.
- **A row no longer repeats the scope you are already inside.** In a workspace it names the
  environment; inside one environment of one workspace it names neither, because both are in the
  title above.
- **Environments have no colours of their own.** Colour already means "which workspace this
  belongs to", and a second palette competing for the same signal was the confusing part. Every
  environment of a project is drawn in the project's colour and told apart by a glyph — laptop,
  hammer, test tube, globe.
- **Clicking a secret's workspace opens that workspace.** It used to narrow the list and leave
  the secret on screen, which showed you none of the page the workspace now has. The environment
  link beside it still keeps the secret open, because narrowing the list is what that one is for.
- **The hover copy button is gone from the item list.** It appeared and disappeared under the
  pointer, shoving the rest of the row aside as you moved down the list. The same copy is on the
  right-click menu and on ⇧⌘C.
- **A `.env` in the detail pane is laid out like the file it came from.** A comment block and the
  variables it introduces are bracketed by a rule down the left, so what a note covers is drawn
  rather than measured by eye; runs of variables are separated, sections spaced wider; comments
  are set in the monospaced style the values use, because they are text out of your file and not
  a caption PassStore wrote. A field's name sits 2pt above its value so the two read as one
  thing, and the sync notice for a variable sits directly under the value it is about.
- **⇧⌘N is New Workspace from Folder…**, the way most workspaces should start. An empty workspace
  is right below it in the same menu.
- **Setup's progress dots are gone.** They were six points tall on a dark, animated backdrop —
  the inactive ones were invisible, and even when you found them they only said "three more of
  something".

### Fixed

- **Writing to a linked `.env` can no longer flatten it.** A write merges into the file on disk,
  but the merge was best-effort: when the read failed it fell through to a document regenerated
  from the secret's fields, deleting every comment, blank line and untracked variable in it. A
  `.env` holding a single non-UTF-8 byte reads as unreadable and writes fine, so that path was
  reachable. The write is now refused, with a reason. Alongside it: a change landing between the
  read and the rename is refused rather than overwritten; a file that moved since the last sync
  is refused explicitly; a write that would change nothing is skipped; a line the secret does not
  touch stays byte-identical; and a changed value keeps the quoting the file used where that is
  still safe — every tracked assignment used to be rebuilt double-quoted, so one Write turned
  into a diff on every line of somebody's file.
- **A successful write is reported as in sync.** It was measured against the file's digest, which
  a merged file never matches.
- **The per-variable baseline records the value both sides agreed on.** An edit landing while the
  file operation was suspended would have been recorded as the synced value, which then blamed
  the secret's own change on the file at the next check.
- **Importing a workspace's `.env` files records that baseline too.** It stored the whole-file
  digests but not the per-variable one, so every later difference in those secrets would have
  read as "both sides changed" instead of naming the side that moved.
- **Copying several `.env` secrets at once gives the same thing as copying one.** A multiple
  selection produced the regenerated form — keys and values, no comments — while a single secret
  produced the file as its owner wrote it. Each file now carries its secret's name above it, so a
  paste of several can be told apart.
- **Asking the sidebar about a workspace shows the workspace.** The detail pane kept describing
  whichever secret happened to be selected.
- **A workspace's "Add" environment tile matches the height of the card beside it** and is
  clickable across its whole area, not only on the word.
- **Missing keys are only counted against environments that hold something**, so a declared but
  empty Staging is not reported as missing every key in the project.
- **Identical values are only a finding for sensitive fields.** `PORT` being the same everywhere
  is how ports work.
- **A variable emptied in the vault but still set in the file stays visible**; hiding it left the
  difference with nothing to click.
- **An environment that empties out falls back to its workspace**, not to the whole vault.
- **The compare sheet has its own padding**, picks up the workspace's tint, and shows each
  environment's glyph in the column head.
- **Pulling a file no longer overwrites your notes.** Notes are yours; the file's comments have
  somewhere better to live now.
- **A variable the secret no longer holds renders as no line at all** rather than as an empty
  assignment, and one added in PassStore is appended. An empty value keeps the bare `KEY=` form
  when that is what the file used.
- **Setting the vault up again no longer leaves a black window.** Erasing the vault takes the
  lock screen straight to onboarding, so for the length of the crossfade both are on screen —
  and each was saving and restoring the window's title bar on its own, which meant the incoming
  one recorded the outgoing one's black as the state to put back. The vault then came up after
  setup with a black window that stayed black until PassStore was quit.
- **The lock screen has no hairline in its top-left corner.** The invisible spacer that holds the
  title bar at its normal height — so the window buttons do not move — was being given the
  toolbar's own background, and drew as a one-point sliver of chrome.
- **Keys compare case-insensitively and keep the spelling they were first given.**

### Security

- **A folder grant reaches everything inside it, so linking one is deliberately narrow.** The
  folder is only ever chosen through a panel that says what it is for. Nothing is scanned at
  unlock or on a timer. Discovery reads names and sizes, never a file body — the first read of
  any contents is the import you confirmed. Symlinks are skipped rather than followed, so a link
  cannot walk out of the folder; depth, result count and the usual dependency directories are
  capped or excluded; and a stored relative path cannot escape the folder it was found in.
  Imported secrets get per-file bookmarks of their own, so unlinking the folder later costs them
  nothing. No new entitlement was needed.
- **Comparing environments does not create a second place secrets are rendered.** Every cell of
  the grid carries presence and a digest, never the thing it digests — so "local and production
  hold the same secret" can be reported without either being displayed. Reading one still means
  opening it.
- **A `.env` layout stored with a secret holds no values.** A value lives only in its field, so
  the remembered shape of a file cannot become a stale copy of a secret.
- **Environment declarations are clamped on the way in**, from the editor and from an untrusted
  backup alike: presets keep their canonical name, duplicates collapse, colours must be hex, and
  a file name can never be a path.
- **Per-variable difference states hold no values** — only which side moved — and are cleared on
  lock like everything else derived from vault contents.

### Compatibility

- **Vaults and `.pstore` backups written by 1.2.x open unchanged.** A vault written by 1.3.0
  stays readable by earlier versions: an environment declaration is organisation metadata only,
  and the authoritative environment of a secret stays where it has always been, on the secret
  itself. A workspace that declares nothing behaves exactly as it did before.
- **A secret imported by an earlier version picks up its file's layout** the first time the file
  is linked or pulled. Until then it renders as it always did.
- **A link made by an earlier version has no per-variable baseline.** A variable that differs is
  reported as diverged rather than attributed to a side that cannot be known; the next sync
  records one.

## [1.2.0] - 2026-08-17

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
- **Restore a backup during setup.** The welcome screen offers "I already have a backup", which
  takes you straight from your new master password to choosing the file — no workspace step to
  invent and no "You're all set" before there is anything to be set up. An empty vault is not
  asked whether to merge or replace, because there is nothing to merge with.
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
- **The welcome and lock screens have a look of their own.** Both now sit on a dark backdrop
  with a slowly drifting glow and an animated pixel grid, the app icon breathing above the
  wordmark set at display size. Everything on them is drawn in solid colours rather than
  translucency, so no button or field dissolves into whatever is moving underneath it. Setup
  runs on the same backdrop from the first screen to the last. The animation stops while
  PassStore is in the background and when Reduce Motion is on.
- **Every yellow button has black text**, in every view and in both light and dark. Some used to
  come out black and others white, because the label colour was picked automatically from the
  fill's brightness. Where the accent is the text rather than what sits behind it, a deeper
  shade of the same yellow is used so it stays readable on a light background.
- **The item header tells you where the item lives.** It runs the full width of the detail pane
  and takes its colour from the workspace, with workspace, type and environment above the name
  and tags below it. All of them are links: click one to see everything else in that workspace,
  of that type, in that environment or with that tag.
- **Sheets have a proper header and footer.** Each opens with a tinted band carrying its icon
  and title, and closes with a pinned row of actions. Picking a template for a new secret is now
  two clean columns of cards that respond to the pointer, rather than a grid boxed inside
  another box.
- **About is a real window**: the app icon, the version you are running, who made it, the
  licence, and links to the repository, the contributing guide, issues and makio.app.
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
- **The lock screen has no leftover toolbar button**, and keeps the close and minimise buttons
  exactly where they sit everywhere else in the app.
- **The sidebar toggle is back in the toolbar** and can also be reached from View → Hide Sidebar
  (⌃⌘S).
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
  Unlock. The Touch ID progress line no longer shifts the buttons up and down mid-unlock.
- **"Passwords don't match" waits until you leave the field.** It used to appear on the first
  character of the confirmation and sit there while you typed the rest.
- **Writing to a linked `.env` works for files outside a folder you have opened.** It reported
  that the file could not be written, having asked for permission to a directory rather than to
  the file you picked.
- **Erasing the vault no longer reports a failure after succeeding.** Clearing a leftover key
  from an old version was treated as a fatal error even though everything had been deleted.
  Erasing now returns you to first-run setup.
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
