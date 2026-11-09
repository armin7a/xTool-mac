# Tresor-Format (Version 1)

Mit dieser Beschreibung lässt sich ein Tresor auch ohne xTool entschlüsseln.

Ort: `~/Library/Containers/ch.xtool.app/Data/Library/Application Support/xTool/Vault`

```
vault.json            Schlüsselparameter und verpackter Hauptschlüssel (Klartext-JSON)
index.bin             verschlüsselter Index
index.bak             vorheriger Stand des Index
attempts-mac.json     Zähler für Fehlversuche, nicht sicherheitsrelevant
blobs/ab/abcd…        verschlüsselte Dateiinhalte (Name = Blob-ID, die ersten zwei Zeichen als Ordner)
```

## Hauptschlüssel

`vault.json` enthält `Version`, `Kdf` ("argon2id"), `MemoryKiB`, `Iterations`, `Parallelism`, `Salt` (Base64, 16 Byte), `WrappedKey` (Base64), `Created`.

1. Passwort als Unicode NFC normalisieren und als UTF-8 kodieren.
2. Argon2id (Version 1.3) mit den Werten aus der Datei, Ausgabe 32 Byte: der Schlüssel `KEK`.
3. `WrappedKey` mit AES-256-GCM und `KEK` öffnen, AAD = `xtool-master-key-v1`. Ergebnis: der 32 Byte lange Hauptschlüssel.

Versiegelte Werte haben den Aufbau `Nonce (12) | Chiffretext | Tag (16)`.

## Index

`index.bin` wird wie oben mit dem Hauptschlüssel geöffnet, AAD = `xtool-index-v1`. Inhalt ist JSON:

- `Version`, `Nodes`, `Notes`, `Boards`, `Settings`
- `Nodes[]`: `Id`, `ParentId` (null = oberste Ebene), `Name`, `Kind` (0 = Ordner, 1 = Datei), `Size`, `BlobId`, `ThumbBlobId`, `Created`, `Modified`, `Accessed`, `DeletedAt`, `Versions[]` (`BlobId`, `Size`, `Saved`)
- Zeitangaben sind ISO-8601-Texte.

## Dateien (Blobs)

```
"XTB1" | Salt (32) | Blockgröße (int32 LE) | Blöcke …
Block: Letzter (1 Byte: 1 = letzter Block) | Länge (int32 LE) | Chiffretext | Tag (16)
```

- Blob-Schlüssel: HKDF-SHA256(Hauptschlüssel, Salt, Info = `xtool-blob-v1:` + Blob-ID), 32 Byte.
- Jeder Block: AES-256-GCM.
  - Nonce: Blocknummer ab 0 als int64 LE, danach 4 Null-Bytes.
  - AAD: Blob-ID (UTF-8) | Blocknummer (int64 LE) | Letzter (1 Byte).
- Eine leere Datei ist genau ein letzter Block der Länge 0.
- Eine Datei ist nur vollständig, wenn ihr letzter Block gelesen wurde und danach nichts mehr folgt.

## Sicherung (.xvault)

Eine ZIP-Datei mit `vault.json`, `index.bin`, `index.bak` und `blobs/` unverändert. Die Inhalte sind gespeichert, nicht komprimiert (bei Bedarf Zip64).

## Passwort ändern

Nur `vault.json` wird neu geschrieben, der Hauptschlüssel bleibt gleich. Das hält den Wechsel schnell. Es bedeutet aber: Wer eine alte `vault.json` oder Sicherung und das alte Passwort hat, kann auch neuere Daten entschlüsseln, falls er an die verschlüsselten Dateien kommt.
