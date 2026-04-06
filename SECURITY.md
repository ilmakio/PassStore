# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |

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

- **`vault.meta`:** wrapped vault key (KDF id, salt, ops/mem limits, AES-GCM nonce, ciphertext, tag — base64 in JSON).
- **`vault.enc`:** encrypted envelope (version, nonce, ciphertext, tag, timestamp).

**Encrypted backup (`.pstore`)**

- Format v3: random export key encrypts the backup JSON; your export password wraps that key using the same Argon2id + AES-GCM pattern as the live vault (`ExportService` in `VaultTransfer.swift`).

**Keychain and Touch ID**

- When biometric unlock is enabled, a copy of the vault key is stored in the macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `biometryCurrentSet` (LocalAuthentication). If biometrics are disabled, that Keychain item is removed.

**On disk**

- Default location: `~/Library/Application Support/app.makio.PassStore/` (or the app bundle id), directory `0700`, `vault.enc` / `vault.meta` `0600`, atomic writes.

**Memory**

- Password bytes used in Argon2id and PBKDF2 paths are zeroed after derivation where the code controls the buffer; the in-memory vault key is cleared on lock; sensitive field values are overwritten when the vault locks (`VaultMemoryStore`). Swift `String` passwords cannot be reliably zeroed (platform limitation).

**Network**

- Vault operations do not transmit vault data. Direct-download builds may use [Sparkle](https://sparkle-project.org/) to fetch an update feed (see `Info.plist`); that is unrelated to encrypting or syncing secrets.

**Code references**

| Area | File |
|------|------|
| Encryption, KDF, vault files | `PassStore/Data/Security/VaultPersistence.swift` |
| Session, auto-lock, clipboard | `PassStore/Data/Security/VaultSecurity.swift` |
| Keychain vault key | `PassStore/Data/Storage/SecretStores.swift` |
| `.pstore` export/import | `PassStore/Data/ImportExport/VaultTransfer.swift` |
