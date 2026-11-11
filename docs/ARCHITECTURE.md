# Architecture

```
Sources/
  XToolCore/          Vault and logic, no user interface
    Crypto/           Aead (small values), KeyDerivation (Argon2id), BlobCipher (files, chunk by chunk), SecretKey
    Vault/            Vault (files on disk), VaultLocation (this Mac or a USB stick), Backup, LoginGuard
    Files/            Drive (folders, trash, versions), DriveRecovery, MetadataScrubber
    Model/            Data model of the index
    Password/         PasswordPolicy, PasswordGenerator, WordLists
    Documents/        Page format of .docx
  XTool/              The app
    App/              Launch, AppModel (app state), Drives (USB sticks), MainView (window), TestTour
    Security/         AutoLock, ScreenGuard, ClipboardGuard, PrivateTextView, ProcessHardening
    Design/           Colors, logo, buttons, shared building blocks: the whole look in one place
    Auth/             Setup, sign-in, password fields
    Files/            FilesView, Transfers (import, export, copy, backup), FileTypes, VersionsView
    Viewers/          PDF, image, text, Office, files without a preview
    Writer/           Document editor
    Notes/ Tasks/ Settings/
Tests/
  XToolCoreTests/     Tests with their own small test runner
  Fixtures/           Frozen vaults from older versions: they must open forever
Vendor/               libsodium (Argon2id) and ZIPFoundation, checked in
Resources/            Logo (original and cropped)
Scripts/              compile.sh, build_app.sh, run_tests.sh, run_dev.sh, make_icon.swift
docs/                 This file, the vault format and the threat model
```

## Rules that hold the code together

- **Only `XToolCore` touches vault files.** The app works exclusively through `Vault` and `Drive`.
- **Large data streams.** `Vault.importBlob`, `exportBlob` and `copyBlob` never hold more than one chunk in memory.
  `readBlob` loads everything and is meant for small content only; `FileTypes.previewLimit` guards it.
- **Save first, delete later.** Replaced content is only deleted once an index without it is on disk (`retireBlob`).
- **Files only appear when complete.** Everything is written to a temporary file and renamed afterwards. This applies to exports too.
- **Exports are cleaned where possible.** `MetadataScrubber` cleans the exported copy, checks it again and only then
  replaces it. A file that cannot be cleaned is left as it was and reported.
- **A new master key never touches the live vault until one atomic rename.** `Vault.renewMasterKey` writes into `rekey/`,
  and `Vault.open` completes or discards an interrupted renewal. While it runs, every read and write fails with `VaultError.busy`
  and an index sealed under an older key is never written.
- **The vault location is chosen once, at the lock screen.** `AppModel.location` decides; nothing else assumes
  `Vault.defaultRoot`. Started from a stick (`AppPlace.launchDrive`), xTool uses the stick. Any unmount of that drive locks.
- **On lock, documents save first**, then the index, then the key is wiped (`AppModel.lock`).
- **The look lives in `Design/DesignSystem.swift`.** Colors and button styles are only defined there.
- **Multi-line text only goes through `PrivateTextView`.** That keeps Writing Tools, Services and web search away from the content. Do not use SwiftUI's `TextEditor`.

## Why custom build scripts?

`Scripts/compile.sh` calls the Swift compiler directly. That needs no network and no Swift Package Manager and still works
when the installed developer tools are partly broken. It also picks the newest macOS SDK the installed compiler can fully use.
`Package.swift` stays so the project opens in Xcode.

For the same reason the tests use neither XCTest nor Swift Testing. New tests go into the list in `Tests/XToolCoreTests/main.swift`.

## Developing

`bash Scripts/run_dev.sh` starts the app with a throwaway vault. `bash Scripts/run_dev.sh tour <folder>` walks through
all screens, checks upload, copy and export, and saves a picture of every screen. Your real vault is never touched.
