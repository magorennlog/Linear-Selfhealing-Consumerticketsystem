# Tracker-Adapter-Vertrag

Ein Adapter ist **ein einziges ausführbares Skript**, das den Skill von einem
konkreten Issue-Tracker entkoppelt. Wer Linear, GitHub Issues, Jira, GitLab,
Redmine … anbinden will, implementiert genau diese vier Verben — der Rest des
Skills bleibt unverändert.

Der Skill ruft den Adapter **nie** mit Roh-API-Aufrufen, sondern immer über
diese Schnittstelle. Dadurch ist der Tracker austauschbar, ohne dass die
Zyklus-Logik (`SKILL.md`) angefasst werden muss.

## Die fünf Verben

| Aufruf | Zweck | Erwartete Ausgabe (stdout) |
|---|---|---|
| `adapter poll` | Liste bearbeitbarer Tickets | Eine Zeile pro Ticket: `id<TAB>ref<TAB>title`, **älteste zuerst** |
| `adapter get <id>` | Ticket-Details | Zeile 1: `ref` · Zeile 2: `title` · Zeile 3: `---` · ab Zeile 4: Beschreibung |
| `adapter comment <ref> "<text>"` | Kommentar anhängen | `OK` bei Erfolg, sonst `FEHLER: …` |
| `adapter move <ref> <state>` | Status ändern | `OK → <neuer Status>` bei Erfolg, sonst `FEHLER: …` |
| `adapter notify <ref> "<text>"` | **Reporter/Ersteller** pingen (z. B. nach Deploy) | `OK` bei Erfolg, sonst `FEHLER: …` |

### `notify` vs. `comment`
`comment` schreibt eine neutrale Notiz ans Ticket. `notify` richtet sich gezielt
an den **Reporter** (Ersteller): wo möglich mit `@mention`, damit er eine
Benachrichtigung bekommt („umgesetzt — bitte testen"). Kann der Adapter den
Reporter nicht auflösen, fällt `notify` auf einen normalen Kommentar zurück
(Subscriber werden ohnehin benachrichtigt). Der Platzhalter `{{REPORTER_MENTION}}`
im Text wird vom Adapter durch die echte Mention (oder leer) ersetzt.

### Begriffe
- **`id`** — die menschenlesbare Kennung (Linear: `ENG-42`, GitHub: `#123`). Erscheint in Branch-Namen, PR-Titeln, Logs.
- **`ref`** — die interne, für Mutationen nötige Referenz (Linear: Issue-UUID, GitHub: Issue-Nummer). Kann mit `id` identisch sein.
- **`state`** — tracker-spezifischer Ziel-Status für `move` (Linear: State-UUID, GitHub: Label/„closed"). Wird aus der Config gereicht.

## Eligibility (was `poll` zurückgibt)

`poll` darf **nur** Tickets liefern, die der Agent anfassen **darf**:
- im konfigurierten Such-Status (`poll_state`),
- mit **einem** der geforderten Labels (`required_label`, komma-separiert ⇒ ODER;
  Default `bug` — für dieses Tool typischerweise `bug,feature`),
- und — falls gesetzt — zusätzlich mit dem Opt-in-Label (`opt_in_label`, z. B. `auto-ok`).

Reportet werden also **Bugs UND Feature-Requests**; welcher Typ vorliegt, entscheidet
nicht der Adapter, sondern das **Council** beim Klassifizieren.

Die De-Duplizierung gegen bereits bearbeitete Tickets (`state_file`) macht der
**Skill**, nicht der Adapter. Der Adapter ist zustandslos.

## Robustheit (Pflicht)

- **Exit-Code 0** nur bei echtem Erfolg. Netz-/Timeout-/Leerantwort → **Exit ≠ 0**
  und Klartext-Fehler nach `stderr` (nie ein leeres stdout, das als „nichts zu
  tun" missgedeutet würde — siehe `linear.sh` für das Retry-Muster).
- Sonderzeichen in Titeln/Bodies dürfen den Aufruf nicht zerbrechen
  (JSON-Payloads über `python3`/`jq` bauen, nicht per String-Interpolation).
- Secrets kommen aus `../.sds-env` (gitignored, `chmod 600`), niemals aus der Config oder dem Repo.

## Mitgelieferte Adapter

- **`linear.sh`** — Linear (GraphQL). Referenz-Implementierung.
- **`github.sh`** — GitHub Issues (via `gh` CLI).
- **`supabase.sh`** — Supabase/PostgREST: Consumer-Reports über ein eigenes
  Formular in eine zentrale Tabelle, projektübergreifend (`project`-Spalte).
  Schema + RLS: `examples/supabase-schema.sql`, Setup: `examples/supabase-consumer.md`.
- **`gitlab.sh`** — GitLab Issues (REST v4, gitlab.com + self-hosted). `move` = Label.
- **`jira.sh`** — Jira Cloud (REST v3, inkl. ADF-Handling). `move` = Workflow-Transition.

Ein neuer Adapter ist fertig, wenn `poll`, `get`, `comment`, `move`, `notify` dem
obigen Vertrag folgen. Smoke-Test: `./adapters/<name>.sh poll` liefert Zeilen oder
leer (Exit 0), `get <id>` zeigt eine Beschreibung.
