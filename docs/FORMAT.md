# Vault format (version 1)

With this description a vault can be decrypted without xTool.

Location on the Mac: `~/Library/Containers/ch.xtool.app/Data/Library/Application Support/xTool/Vault`

On a USB stick or other drive: the folder `xTool Vault` at the top of the drive. The content is identical.

```
vault.json            key parameters and the wrapped master key (plain JSON)
index.bin             encrypted index
index.bak             previous state of the index
attempts-mac.json     counter for failed attempts, not security relevant
blobs/ab/abcd…        encrypted file contents (name = blob ID, first two characters as folder)
```

## Master key

`vault.json` contains `Version`, `Kdf` ("argon2id"), `MemoryKiB`, `Iterations`, `Parallelism`, `Salt` (Base64, 16 bytes), `WrappedKey` (Base64), `Created`.

1. Normalize the password to Unicode NFC and encode it as UTF-8.
2. Argon2id (version 1.3) with the values from the file, 32 bytes of output: the key `KEK`.
3. Open `WrappedKey` with AES-256-GCM and `KEK`, AAD = `xtool-master-key-v1`. The result is the 32-byte master key.

Sealed values are laid out as `nonce (12) | ciphertext | tag (16)`.

New vaults use 1 GiB of memory, 3 iterations and 1 lane. Older vaults are moved to these values the next time they are unlocked.

## Index

`index.bin` is opened like above with the master key, AAD = `xtool-index-v1`. Its content is JSON:

- `Version`, `Nodes`, `Notes`, `Boards`, `Settings`
- `Nodes[]`: `Id`, `ParentId` (null = top level), `Name`, `Kind` (0 = folder, 1 = file), `Size`, `BlobId`, `ThumbBlobId`, `Created`, `Modified`, `Accessed`, `DeletedAt`, `Versions[]` (`BlobId`, `Size`, `Saved`)
- Times are ISO 8601 strings.

## Files (blobs)

```
"XTB1" | salt (32) | chunk size (int32 LE) | chunks …
chunk: final (1 byte: 1 = last chunk) | length (int32 LE) | ciphertext | tag (16)
```

- Blob key: HKDF-SHA256(master key, salt, info = `xtool-blob-v1:` + blob ID), 32 bytes.
- Every chunk: AES-256-GCM.
  - Nonce: chunk number from 0 as int64 LE, followed by 4 zero bytes.
  - AAD: blob ID (UTF-8) | chunk number (int64 LE) | final (1 byte).
- An empty file is exactly one final chunk of length 0.
- A file is only complete when its final chunk has been read and nothing follows it.

## Backup (.xvault)

A ZIP file with `vault.json`, `index.bin`, `index.bak` and `blobs/` unchanged. The entries are stored, not compressed (Zip64 if needed).

## Changing the password

Only `vault.json` is rewritten; the master key stays the same. That keeps the change fast. It also means: whoever has an
old `vault.json` or backup and the old password can decrypt newer data too, if they get hold of the encrypted files.
See [THREAT_MODEL.md](THREAT_MODEL.md#changing-the-password).

## Renewing the master key

A new random master key replaces the old one; the format stays version 1. Every blob keeps its ID and is encrypted
again with a fresh salt under the new key; the index is sealed with the new key.

Everything new is first written to `rekey/` inside the vault folder:

```
rekey/blobs/ab/abcd…   the re-encrypted blobs              (written first)
rekey/index.bin        the index sealed with the new key
rekey/vault.json       the new key, wrapped with the password
rekey/keep.txt         IDs of all blobs that belong to the vault afterwards, one per line   (written last)
```

The commit point is the atomic rename of `rekey/vault.json` to `vault.json`. When a vault is opened:

- `rekey/vault.json` exists, or `rekey/keep.txt` does not: the renewal never committed (or has already finished).
  `rekey/` is deleted; the vault is complete as it is.
- `rekey/keep.txt` exists without `rekey/vault.json`: the renewal committed. `rekey/index.bin` becomes `index.bin` (and `index.bak`),
  the blobs in `rekey/blobs` replace those in `blobs/`, every blob not listed in `keep.txt` is overwritten and deleted,
  then `keep.txt` and the rest of `rekey/` are removed. All of this needs no key.
