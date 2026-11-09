# Aufbau

```
Sources/
  XToolCore/          Tresor und Logik, ohne Oberfläche
    Crypto/           Aead (kleine Werte), KeyDerivation (Argon2id), BlobCipher (Dateien, blockweise)
    Vault/            Vault (Dateien auf der Platte), Backup, LoginGuard
    Files/            Drive (Ordner, Papierkorb, Versionen), DriveRecovery
    Model/            Datenmodell des Index
    Password/         PasswordPolicy, PasswordGenerator, WordLists
    Documents/        Seitenformat von .docx
  XTool/              Die App
    App/              Start, AppModel (App-Zustand), MainView (Fenster), TestTour
    Security/         AutoLock, ScreenGuard, ClipboardGuard, PrivateTextView, ProcessHardening
    Design/           Farben, Logo, Buttons, gemeinsame Bausteine: das ganze Aussehen an einer Stelle
    Auth/             Einrichten, Anmelden, Passwortfelder
    Files/            FilesView, Transfers (Import, Export, Kopie, Sicherung), FileTypes, VersionsView
    Viewers/          PDF, Bild, Text, Office, Dateien ohne Vorschau
    Writer/           Dokument-Editor
    Notes/ Tasks/ Settings/
Tests/
  XToolCoreTests/     Tests mit eigenem kleinem Test-Runner
  Fixtures/           Eingefrorene Tresore alter Versionen: müssen sich für immer öffnen lassen
Vendor/               libsodium (Argon2id) und ZIPFoundation, fest eingecheckt
Resources/            Logo (Original und Zuschnitt)
Scripts/              compile.sh, build_app.sh, run_tests.sh, run_dev.sh, make_icon.swift
docs/                 Diese Datei und das Tresor-Format
```

## Regeln, die den Code zusammenhalten

- **Nur `XToolCore` fasst Tresordateien an.** Die App arbeitet ausschließlich über `Vault` und `Drive`.
- **Große Daten laufen als Strom.** `Vault.importBlob`, `exportBlob` und `copyBlob` halten nie mehr als einen Block im Speicher. `readBlob` lädt alles und ist nur für kleine Inhalte gedacht; `FileTypes.previewLimit` wacht darüber.
- **Erst sichern, dann löschen.** Ein ersetzter Inhalt wird erst gelöscht, wenn ein Index ohne ihn auf der Platte liegt (`retireBlob`).
- **Dateien erscheinen erst, wenn sie vollständig sind.** Alles wird in eine Temp-Datei geschrieben und danach umbenannt. Das gilt auch für Exporte.
- **Beim Sperren speichern erst die Dokumente**, dann der Index, dann wird der Schlüssel gelöscht (`AppModel.lock`).
- **Das Aussehen steht in `Design/DesignSystem.swift`.** Farben und Button-Stile werden nur dort definiert.
- **Mehrzeiliger Text läuft nur über `PrivateTextView`.** So kommen Schreibwerkzeuge, Dienste und Websuche von macOS nicht an den Inhalt. Kein SwiftUI-`TextEditor` verwenden.

## Warum eigene Build-Skripte?

`Scripts/compile.sh` ruft direkt den Swift-Compiler auf. Das kommt ohne Netz und ohne Swift Package Manager aus und läuft auch, wenn die installierten Entwicklerwerkzeuge teilweise beschädigt sind. `Package.swift` bleibt, damit sich das Projekt in Xcode öffnen lässt.

Die Tests nutzen aus demselben Grund weder XCTest noch Swift Testing. Neue Tests kommen in die Liste in `Tests/XToolCoreTests/main.swift`.

## Entwickeln

`bash Scripts/run_dev.sh` startet die App mit einem Wegwerf-Tresor. `bash Scripts/run_dev.sh tour <ordner>` läuft durch alle Bildschirme, prüft Upload, Kopie und Export und speichert von jedem Bildschirm ein Bild. Der echte Tresor wird dabei nicht berührt.
