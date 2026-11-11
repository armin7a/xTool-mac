# Threat model

This page says plainly what xTool protects against and what it does not. Read it before you trust xTool with
anything that could put you or other people at risk.

xTool has **not been audited** by an independent security firm. The design and code are open so anyone can check them.

## What xTool protects

Your files, documents, notes and tasks while they are **inside the vault and the vault is locked**.

| Situation | Protected? | Why |
|---|---|---|
| Your Mac is lost or stolen while xTool is locked | **Yes** | Everything in the vault is encrypted with AES-256-GCM. Without the password the data cannot be read. |
| Someone copies the vault folder, a Time Machine backup or an `.xvault` backup | **Yes**, if your password is strong | Each password guess costs 1 GB of memory and 3 passes of Argon2id. A strong password (6 random words, or 16+ random characters) is out of reach. |
| Someone changes or swaps encrypted data | **Detected** | Every block carries an authentication tag. Tampered or truncated files fail to open instead of showing wrong content. |
| Someone looks over your shoulder or records the screen | **Partly** | xTool locks after 1 minute without activity, on sleep, on screen lock and when you close the lid. Its windows are hidden from screenshots, screen recordings and screen sharing (Settings). This does not stop a camera pointed at the screen. |
| Text you type leaving through macOS features | **Yes, by default** | Writing Tools, Services, Look Up, Translate and web search are switched off in xTool's editors. Spell checking is off unless you turn it on. |
| Text you copy staying on the clipboard | **Yes** | What you copy from xTool is cleared from the clipboard after 2 minutes and when the vault locks. It is marked as confidential so clipboard managers skip it, and it is not shared with your other Apple devices. |
| Exported photos and documents revealing who you are or where you were | **Yes, for common types** | When you export, photos lose GPS position, camera and dates. PDFs and Word, Excel and PowerPoint files lose author, editor and company. See [Metadata](#metadata). |
| Network snooping | **Not applicable** | xTool has no network access at all (App Sandbox without network entitlement). It sends nothing anywhere. |

## What xTool does not protect against

Be honest with yourself about these. Most real attacks on journalists and activists are of this kind.

- **Malware or spyware on your Mac.** If someone controls your Mac (for example commercial spyware such as Pegasus or a
  keylogger), they can read your password as you type it and see everything you open. No app can protect against a
  compromised operating system. Keep macOS updated, and consider Lockdown Mode.
- **Your Mac taken while xTool is unlocked.** An open vault is open. Lock it (⌃⌘L) before you leave the Mac, cross a
  border or go into a risky situation. Better still: shut the Mac down.
- **Being forced to give up the password.** xTool cannot help if you are made to unlock it. See [Hidden vaults](#hidden-vaults).
- **A weak password.** Encryption is only as strong as the password. `Summer2024!` falls in seconds, six random words do not.
  xTool refuses weak new passwords and suggests strong ones.
- **Files after you export them.** Exported files are normal, unencrypted files. xTool warns before every export.
  Delete them when you no longer need them. On SSDs, deleted files cannot be reliably wiped, so turn on FileVault.
- **That you use xTool.** The app, the vault folder, the number of encrypted files, their approximate sizes and
  when they changed are visible to anyone with access to your Mac. File names, folder names and contents are not.
- **Communication.** xTool stores data. It is not a messenger and not a way to receive material from sources.
  Use tools built for that, such as Signal or SecureDrop.

## Recommendations for journalists

1. Turn on **FileVault** (System Settings → Privacy & Security). It protects everything else on your Mac, including exported files.
2. Use a **passphrase of six random words** (xTool's **Suggest Password** does this) and use it nowhere else.
3. Leave **automatic lock at 1 minute** and lock manually with ⌃⌘L when you step away.
4. Keep **"Remove metadata when exporting"** on. Originals in the vault keep their metadata, which can matter as evidence
   (where and when a photo was taken). Only exported copies are cleaned.
5. Make **backups** (`.xvault`) to an external drive you keep somewhere else. They stay encrypted.
6. Before a border crossing or a search, **shut the Mac down**. A locked xTool on a running Mac is safe, but a Mac that is off
   is safer still: the operating system then holds no keys in memory at all.
7. If you think your password was seen, **change it**, then read [Changing the password](#changing-the-password).

## Metadata

With **Settings → Remove metadata when exporting** turned on (the default), exported copies are cleaned. The file inside the vault never changes.

| Type | What is removed | Notes |
|---|---|---|
| JPEG, PNG, HEIC, TIFF | GPS position, camera and lens, dates, names, comments, IPTC and XMP | JPEG keeps its image data bit for bit. HEIC is re-encoded at high quality, PNG and TIFF without loss. Orientation is kept. |
| PDF | Author, title, keywords, creator app, XMP, attachments, scripts, form fields | The PDF is rebuilt page by page, like "Print to PDF". Text stays selectable. Links, bookmarks and fillable fields are lost; annotations become part of the page. |
| Word, Excel, PowerPoint (.docx, .xlsx, .pptx) | Author, last editor, company, manager, times, custom properties, names on comments and tracked changes | The content, comments and changes themselves stay. |
| Everything else (videos, audio, archives, …) | Nothing | Videos in particular can contain GPS. Clean them with a dedicated tool before sharing. |

After cleaning, xTool reads every file again and checks that nothing identifying is left. If a file cannot be cleaned
(for example a password-protected PDF), it is exported unchanged and xTool tells you which files they are.

What metadata removal cannot do: remove information that is part of the content itself, such as a face, a street sign
or a reflection in a photo, the text of a document, a printer's tracking dots, or the way a person writes.

## Changing the password

The password does not encrypt your files directly. It unlocks a random 256-bit master key, and the master key encrypts
the files. Changing the password re-wraps the master key with the new password: this takes a second, even for a vault of 100 GB.

The consequence: anyone who has an **old copy** of `vault.json` (for example from Time Machine or an old `.xvault` backup)
**and** knows the **old password** can still recover the master key. If they also get a copy of the encrypted files,
they can read them, including files added later.

So if your old password was compromised: change it, then create a fresh backup and delete old backups and old Time Machine
snapshots of the vault. A future version will offer to re-encrypt everything with a new master key.

## Hidden vaults

Some tools offer a second, hidden vault that opens with a different password, so you can give up a harmless one under
pressure ("plausible deniability"). xTool deliberately does not offer this, because done badly it is more dangerous than not having it:

- On a Mac with an SSD and APFS, the file system, snapshots and Time Machine leave traces of how much data was written
  and when. A forensic examiner can often tell that more data exists than the harmless vault explains.
- An adversary who knows the software supports hidden vaults may simply not believe you, whatever you open.
- A false sense of safety leads people to keep material they would otherwise not carry at all.

The safer practice is to not carry sensitive material through risky situations: keep it in an encrypted backup elsewhere and travel with a Mac that does not hold it.

## Hardware keys

xTool currently uses only a password. A hardware key (for example a YubiKey) as a second factor is being considered.
It would protect a stolen copy of the vault even if the password became known, but it would also lock you out
for good if the key is lost and no backup key exists.

## Details

- Cryptography: libsodium (Argon2id) and Apple CryptoKit (AES-256-GCM, HKDF-SHA256). No custom cryptography.
- The master key lives in locked memory (not swapped to disk where the system allows it) and is overwritten when the vault locks.
- Decrypted content is only held in memory while you view it. Nothing decrypted is written to disk except files you export.
- After failed passwords, xTool waits 1, 2, 4 … up to 30 seconds. This slows guessing in the app only; someone with a copy
  of the vault guesses offline, which is why the Argon2id cost and the password strength matter.
- Core dumps are disabled, windows are not restored after a restart, and dictation is off.
- The file format is fully documented in [FORMAT.md](FORMAT.md).

Found a security problem? Please see [SECURITY.md](../SECURITY.md).
