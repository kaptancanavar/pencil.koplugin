# Pencil ✏️

Ein KOReader-Plugin, mit dem du mit dem Stift direkt in deine Bücher und PDFs schreiben kannst. Zum Beispiel Notizen an den Rand, etwas unterstreichen oder einfach drauflos kritzeln.

## Was kann es?

- **Stift**: freihand zeichnen und schreiben
- **Textmarker**: breit und halbtransparent
- **Radierer**: radiert nur das weg, was unter dem Radierer liegt, oder auf Wunsch den ganzen Strich
- **Lasso**: Striche einkreisen und dann verschieben oder löschen
- **Notizzettel**: auf die Seite tippen und eine Textnotiz anheften
- **Rückgängig / Wiederholen**
- **Schwebende Werkzeugleiste**: lässt sich verschieben und einklappen
- **Pointer-Modus**: der Stift verhält sich wie ein Finger, z. B. zum Umblättern oder für Menüs
- Unterstützung für **Radiergummi-Ende** und **Seitentaste** am Stift, wenn das Gerät sie meldet

Ein paar Sachen sind noch experimentell und standardmäßig aus. Du findest sie im Menü unter *Pencil → Experimental*:

- Farbwähler (Stift kurz still halten)
- Strichstärken-Auswahl
- Echte KOReader-Textmarkierungen mit der Seitentaste
- Lesezeichen für Seiten mit Anmerkungen

## Installation

1. Den Ordner `pencil.koplugin` in den `plugins`-Ordner von KOReader kopieren.
   - Kindle: `koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
2. KOReader neu starten.
3. Ein Buch öffnen. Unter **Werkzeuge → Pencil** findest du jetzt das Plugin.

Das Plugin läuft nur auf Geräten mit Touchscreen. Sinnvoll ist es natürlich nur mit einem Stift.

## Bedienung

- Die Werkzeugleiste erscheint, sobald ein Buch offen ist. Du kannst sie über *Pencil → Show toolbar* ein- und ausblenden.
- Tippst du auf das Werkzeug, das schon aktiv ist, öffnet sich die Auswahl der Strichstärke.
- Den runden Griff ziehst du, um die Leiste zu verschieben. Ein Tippen darauf klappt sie ein.
- Ein kurzer Druck auf die Seitentaste des Stifts blendet die Leiste ein oder aus.
- Mehrere Aktionen kannst du in KOReader auf Gesten legen, z. B. Werkzeug wechseln, Plugin an/aus oder Rückgängig.

## Wo werden die Daten gespeichert?

Alles liegt neben dem Buch im Sidecar-Ordner (`.sdr`):

- `pencil_strokes.lua`: alle Striche und Notizen
- `pencil_images/`: kleine Vorschaubilder der Anmerkungen. Sie werden z. B. nach dem Drehen des Geräts gebraucht. Über das Menü kannst du sie löschen.

Wenn du das Buch samt `.sdr`-Ordner kopierst, kommen deine Anmerkungen also mit.

## Probleme?

Falls der Stift nicht richtig erkannt wird, kannst du unter *Pencil* den **Input debug mode** einschalten. Dann schreibt das Plugin alle Eingaben in `pencil_input_debug.log` im KOReader-Datenordner. Damit lässt sich meistens herausfinden, was das Gerät eigentlich sendet.

## Aufbau (für Neugierige)

```
main.lua      Einstiegspunkt, setzt das Plugin zusammen
_meta.lua     Name und Beschreibung für KOReader
pencil/       die einzelnen Funktionen (Radieren, Lasso, Notizen, Speichern, …)
lib/          Werkzeugleiste und Geometrie-Helfer
icons/        SVG-Icons für die Werkzeugleiste
```
