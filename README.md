# xTool

Dein privater, verschlüsselter Tresor für den Mac: Dateien, Dokumente, Notizen und Aufgaben. Alles bleibt auf deinem MacBook: xTool hat keinen Netzwerkzugriff.

## Installieren

1. Die App bauen (siehe „Selbst bauen“ unten). Das ergibt `dist/xTool-2.0.0.dmg`.
2. Die DMG öffnen und **xTool** in den Programme-Ordner ziehen. Ein bestehender Tresor bleibt erhalten.

Falls macOS beim ersten Start warnt: **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen**.

## Bedienung

| Was | Wie |
|---|---|
| Dateien hinzufügen | In das Fenster ziehen, `+` oder ⌘O |
| Dateien herausholen | Auswählen → **Exportieren** oder ⇧⌘E |
| Alles herausholen | Einstellungen → Alle Dateien → Exportieren |
| Sperren | Schloss unten links oder ⌃⌘L. Passiert auch beim Zuklappen. |
| Bereiche wechseln | ⌘1 bis ⌘5, Einstellungen ⌘, |
| Tabs | ⌘W schließen, ⇧⌘] und ⇧⌘[ wechseln |
| Fokusmodus | ⌃⌘F |

### Dokumente

Der Writer zeigt echte Seiten, standardmäßig A4 (umstellbar unter **Layout**). Schreibst du über das Seitenende hinaus, geht es automatisch auf der nächsten Seite weiter. Kopf- und Fußzeile sowie Seitenzahlen erscheinen auf jeder Seite, die Statusleiste zeigt „Seite 2 von 5“. Ein PDF sieht genauso aus wie die Seiten auf dem Bildschirm.

### Große Dateien

Die Dateigröße begrenzt nur dein freier Speicher: xTool verschlüsselt immer nur 1 MB auf einmal. Während einer Übertragung bleibt das MacBook wach und die automatische Sperre pausiert. Zuklappen sperrt trotzdem und bricht die Übertragung ab; fertige Dateien bleiben erhalten.

Bis zu dieser Größe zeigt xTool eine Vorschau, darüber exportierst du die Datei zum Öffnen: Text 20 MB, Bilder und Office 256 MB, PDF 1 GB. Video, Audio und Archive haben keine Vorschau.

### Passwort

Neue Passwörter müssen mindestens 12 Zeichen haben und dürfen nicht leicht zu erraten sein. xTool zählt dafür nicht nur Sonderzeichen, sondern schätzt, was ein Angreifer probieren würde: bekannte Passwörter, Wörter, Tastaturreihen, Wiederholungen, Jahreszahlen. `Sommer2024!` fällt durch, vier zufällige Wörter bestehen. **Passwort vorschlagen** erzeugt sechs zufällige Wörter.

Ein bestehendes schwächeres Passwort funktioniert weiter; xTool empfiehlt dann nur, es zu ändern. Vergessene Passwörter kann niemand zurücksetzen.

### Abschottung

- Der Text bleibt in xTool: Schreibwerkzeuge, Dienste, Websuche und Teilen von macOS sind in den Editoren abgeschaltet. Die Rechtschreibprüfung ist aus und lässt sich in den Einstellungen einschalten.
- Was du aus xTool kopierst, wird beim Sperren aus der Zwischenablage entfernt und nicht auf andere Geräte übertragen.
- Standardmäßig sperrt xTool nach 1 Minute ohne Aktivität.
- Vor jedem Export warnt xTool, denn exportierte Dateien sind nicht mehr verschlüsselt.

### Sicherung

Einstellungen → Sicherung erzeugt eine `.xvault`-Datei. Sie bleibt verschlüsselt und braucht das Passwort, das beim Erstellen galt. Beim Einspielen prüft xTool erst Passwort und Inhalt, dann wird der Tresor ersetzt; der alte bleibt daneben erhalten. Auf einem neuen Mac geht das direkt im Startbildschirm.

## Langlebigkeit

xTool braucht keine Updates, um weiterzulaufen: kein Server, kein Konto, keine Lizenz, kein Ablaufdatum. Es läuft ab macOS 14, auf Apple Silicon und Intel.

Eine Garantie für alle künftigen macOS-Versionen kann es trotzdem nicht geben, das entscheidet Apple. Deshalb hängen deine Daten nicht an der App:

- **Export:** Du kannst jederzeit alles unverschlüsselt herausholen.
- **Offenes Format:** [docs/FORMAT.md](docs/FORMAT.md) beschreibt den Tresor vollständig, er ließe sich auch ohne xTool entschlüsseln.
- **Neu bauen:** Alle Abhängigkeiten liegen in `Vendor/`, der Build braucht kein Internet.

Mach regelmäßig eine Sicherung auf einen anderen Datenträger. Die schützt auch vor einem defekten MacBook.

## Selbst bauen

Voraussetzung sind die Xcode Command Line Tools (`xcode-select --install`).

```bash
bash Scripts/build_app.sh
```

```bash
bash Scripts/run_tests.sh
```

Aufbau des Codes: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Lizenz

xTool ist Open Source unter der [MIT-Lizenz](LICENSE): Du darfst den Code frei verwenden, verändern und weitergeben, auch kommerziell, solange der Lizenzhinweis erhalten bleibt.

Ausgenommen ist das Logo, daran bleiben alle Rechte vorbehalten. Die Bibliotheken in `Vendor/` stehen unter ihren eigenen Lizenzen: libsodium und swift-sodium (ISC), ZIPFoundation (MIT).

## Sicherheit

Die Sicherheit von xTool beruht allein auf deinem Passwort, nicht auf geheimem Code. Deshalb kann der Code offen liegen: Jeder darf prüfen, wie verschlüsselt wird ([docs/FORMAT.md](docs/FORMAT.md)). Die Test-Tresore in `Tests/Fixtures/` enthalten nur erfundene Beispieldaten, ihr Passwort steht absichtlich in den Tests.
