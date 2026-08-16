# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.2.x   | Yes       |
| 1.1.x   | Yes       |
| 1.0.x   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability in PassStore, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, email **feedback@makio.app** with:

- A description of the vulnerability
- Steps to reproduce the issue
- Any potential impact assessment

You should receive a response within 48 hours. We will work with you to understand and address the issue before any public disclosure.

## How PassStore protects data (summary)

The canonical **user-facing** security write-up (threat model, session, clipboard, updates) is **[passstore.makio.app/security](https://passstore.makio.app/security)**. The bullets below are the in-repo technical summary aligned with the source.

**Cryptography (at rest)**

- **Vault payload:** AES-256-GCM (Apple CryptoKit). Vault snapshot is JSON, then encrypted with a random 256-bit vault key.
- **Password → vault key:** Argon2id via libsodium (swift-sodium): 16-byte salt, opsLimit `3`, memLimit 256 MiB. Legacy vaults use PBKDF2-HMAC-SHA256 (600 000 iterations); on first successful unlock they are re-wrapped with Argon2id automatically.
- **No custom ciphers.**

**Key hierarchy (short)**

- Master password never encrypts item data directly: KDF → derived key → AES-GCM unwraps a random **vault key** → that key AES-GCM-encrypts the vault JSON.

**On-disk artifacts**

- **`vault.package`:** authoritative atomic package containing the wrapped vault key metadata and encrypted vault envelope.
- **`vault.meta` / `vault.enc`:** owner-only compatibility mirrors for older PassStore versions; current builds never fall back to them while `vault.package` exists, even if the package is corrupt.
- **`vault.rollback`:** owner-only atomic recovery package created before a destructive restore. The vault and rollback settings remain AES-256-GCM encrypted; pre-release 1.2 rollback files with legacy plaintext settings are read only for recovery and are never newly written.
- Custom tag and environment ordering is stored inside the encrypted vault, not in `UserDefaults`; plaintext keys written by pre-release 1.2 builds are migrated and removed after a successful unlock.

**Encrypted backup (`.pstore`)**

- Format v3: random export key encrypts the backup JSON; your export password wraps that key using the same Argon2id + AES-GCM pattern as the live vault (`ExportService` in `VaultTransfer.swift`).

**Keychain and Touch ID**

- When biometric unlock is enabled, a copy of the vault key is stored in the macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `biometryCurrentSet` (LocalAuthentication). If biometrics are disabled, that Keychain item is removed.

**On disk**

- Default location: `~/Library/Application Support/app.makio.PassStore/` (or the app bundle id), directory `0700`; vault, compatibility mirrors and rollback files are `0600` and use atomic replacement.

**Previous values (1.2.0)**

- Replacing a secret keeps the value it replaced, capped at 10 versions per field, inside the same encrypted payload as everything else. This is opt-out (Settings → Data), purgeable per item and vault-wide, and cleared from memory on lock along with the live values. It does mean a rotated secret stays recoverable from the vault until purged — rotate *and* purge if a value was leaked.

**Linked files (1.2.0)**

- An item may store an app-scoped security bookmark to the `.env` it mirrors. The bookmark grants PassStore access to that one file. PassStore reads linked files when you open their status or bring the app to the front (if the setting is enabled), and releases access immediately afterwards. It writes only after you press **Write** and confirm any conflict; no file is watched continuously. Generated values are quoted and shell expansion characters are escaped before writing.

**Global shortcut**

- ⌘⌥P is registered with the window server (`RegisterEventHotKey`). PassStore does not request Accessibility permission and does not observe keystrokes outside its own windows. Before 1.2.0 it installed a global `NSEvent` monitor, which required Accessibility and delivered every keystroke from every application to the app.

**Memory**

- Password bytes used in Argon2id and PBKDF2 paths are zeroed after derivation where the code controls the buffer; the in-memory vault key, all decrypted item/workspace/template strings, private sidebar metadata, previous values, decrypted import previews and undo snapshots are cleared on lock. Swift `String` passwords cannot be reliably zeroed (platform limitation).

**Network**

- Vault operations do not transmit vault data. Direct-download builds may use [Sparkle](https://sparkle-project.org/) to fetch an update feed (see `Info.plist`); that is unrelated to encrypting or syncing secrets.

**Code references**

| Area | File |
|------|------|
| Encryption, KDF, vault files | `PassStore/Data/Security/VaultPersistence.swift` |
| Session, auto-lock, clipboard | `PassStore/Data/Security/VaultSecurity.swift` |
| Keychain vault key | `PassStore/Data/Storage/SecretStores.swift` |
| `.pstore` export/import | `PassStore/Data/ImportExport/VaultTransfer.swift` |
