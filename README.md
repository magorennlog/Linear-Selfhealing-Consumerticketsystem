# Selfdeveloping System

> Ein Claude-Code-Skill, der ein Software-Projekt seine **eigenen gemeldeten Bugs
> UND Feature-Requests abarbeiten lässt** — pollt den Tracker, lässt ein
> **Council** (Gremium aus mehreren LLM-Linsen) jeden Report prüfen, fixt
> **genau einen** eindeutigen Fall auf einem Branch, verifiziert mit Tests, einem
> deterministischen Pfad-Gate **und** einem zweiten Council-Votum, und öffnet
> einen PR. Ist das Gremium auf **beiden Achsen** sicher genug (echter Fall? Fix
> korrekt? — Default ≥ **75 %**) und das Pfad-Gate sauber, wird **direkt deployt**
> und der Reporter benachrichtigt. Sonst landet die Änderung in der **manuellen
> Freigabe-Warteschlange**.

Das System „entwickelt sich selbst weiter": sein eigener Tracker triggert
Korrekturen an seinem eigenen Code. Sicherheit ist nicht ein Feature, sondern die
Architektur — Auto-Deploy ist **opt-in** und **mehrfach gated** (Council-Schwelle
+ Pfad-Gate-Veto + grüne Tests).

```
Mensch meldet Bug / Feature   →   Tracker (Linear · GitHub · …)
        │
        ▼
Selfdeveloping-System-Zyklus  (geplant, z. B. alle 6 h)
  1 Poll      ein eligibles Ticket (Label bug|feature + Status + nicht schon bearbeitet)
  2 Council   N Linsen klassifizieren → council-decide.sh: echter Fall? sonst ESKALIEREN
  3 Fix       Branch · minimaler Fix/Feature · Tests grün?  sonst → eskalieren
  4 Gate      bin/guardrail-check.sh: verbotene Pfade?  → BLOCK = kein PR/Deploy (absolutes Veto)
  5 Council   N Linsen + Refuter verifizieren das Diff (Fix korrekt?)
  6 PR        gh pr create  (immer — auch als Audit-Spur)
  7 Entscheid council-decide.sh deploy:
               ├─ beide Achsen ≥ Schwelle & Gate PASS → bin/deploy.sh MERGE+DEPLOY → Reporter pingen
               └─ sonst → manuelle Freigabe-Warteschlange (PR bleibt offen)
        │
        ▼
  Auto-Deploy (live)  ODER  Mensch reviewt & MERGT   ◀── zwei Tore, je nach Confidence
```

---

## Warum das anders ist als die üblichen Auto-Fix-Agenten

Die meisten autonomen Issue→PR-Agenten (GitHub Copilot Coding Agent, Sweep,
OpenHands, Devin …) laufen in einer **Cloud-VM** und stützen Sicherheit primär
auf Prompts und Review-am-Ende. Dieser Skill setzt vier Dinge anders:

| | Selfdeveloping System | Typische Cloud-Agenten |
|---|---|---|
| **Wo es läuft** | Lokal / dein Runner — **Code verlässt die Maschine nie** (DSGVO-tauglich) | Cloud-VM des Anbieters |
| **Triage** | **Council** aus mehreren Linsen + deterministische Schwelle, vor jedem Fix | meist Einzel-Prompt |
| **Verbotene Bereiche** | **Deterministische Deny-Liste**, vor PR **und** vor Deploy gegen das echte Diff geprüft — unumgehbar | meist nur Prompt-Bitten, kein eingebautes Path-Exclude |
| **Umfang pro Lauf** | **Genau 1 Ticket, 1 Versuch** — maximal auditierbar, kein Retry-Spinning | oft mehrere parallel, Retry-Schleifen |
| **Endpunkt** | **Confidence-gated:** ≥ Schwelle → Auto-Deploy; sonst manuelle Warteschlange | meist fix (nur PR oder immer Merge) |
| **Tracker** | **Adapter-Interface** (Linear/GitHub/eigener), Bugs **und** Features | meist GitHub-only, Bug-fokussiert |

Das stärkste Stück ist das **deterministische Gate**: `bin/guardrail-check.sh`
difft den Branch gegen `base` und blockt, sobald eine Datei eine Regel aus
`guardrails.deny` berührt (Schema, Auth, Migrations, Secrets, Kern-Geschäftslogik,
Deploy …). Das ist unabhängig davon, was der Agent „vorhatte" — die Grenze ist
Code, keine Bitte. Beim Auto-Deploy prüft `bin/deploy.sh` dasselbe Gate **noch
einmal** unmittelbar vor dem Merge (defense in depth): verbotene Pfade werden
**nie** automatisch ausgerollt, egal wie hoch die Council-Confidence ist.

Das zweite Stück ist das **Council** (STORM- / LLM-Council-Prinzip): mehrere
Linsen (`reproducer`, `scope-skeptic`, `security-warden`, `product-judge` + ein
`refuter` bei der Fix-Verifikation) bewerten jeden Report unabhängig und schreiben
strukturierte JSON-Urteile. Die **Schwellen-Entscheidung** trifft danach
`bin/council-decide.sh` deterministisch — der Agent liefert Confidence-Zahlen,
umgeht die Logik aber nicht.

---

## Installation

Voraussetzungen: `bash`, `python3`, `git`, `gh` (GitHub CLI, eingeloggt), Claude Code.

```bash
# In DEIN Projekt-Repo:
git clone https://github.com/magorennlog/Linear-Selfhealing-Consumerticketsystem \
  .claude/skills/selfdeveloping-system

# Ein Befehl richtet alles ein (kopiert Vorlagen, chmod, .sds-state/, prüft Tools):
bash .claude/skills/selfdeveloping-system/bin/install.sh
```

`install.sh` ist idempotent — es überschreibt vorhandene `config.yml`/`.sds-env`/
`guardrails.deny` nicht, legt das Audit-Verzeichnis `.sds-state/` an und prüft die
Voraussetzungen. Danach die drei Dateien anpassen (s. u.).

Der Skill ist jetzt unter `/selfdeveloping-system` in Claude Code aufrufbar.

**Vertrauen prüfen:** `bash bin/selftest.sh` fährt Fixture-Tests gegen beide
deterministischen Gates (Pfad-Veto, Datei-Obergrenze, leerer Branch; 75 %-Schwelle,
`floor`, Einstimmigkeit, Refuter-Veto). Braucht nur `bash`/`git`/`python3` und
fasst dein Projekt nicht an — grün heißt: die Sicherheits-Logik greift wie beschrieben.

---

## Konfiguration

Drei Dateien, klar getrennt:

| Datei | Inhalt | Committen? |
|---|---|---|
| **`config.yml`** | Verhalten: Branch, Test-Befehle, Limits, Sprache, Modus | in DEIN Projekt-Repo: ja |
| **`.sds-env`** | Secrets + Tracker-IDs (API-Key, Team-/State-IDs) | **niemals** (gitignored, `chmod 600`) |
| **`guardrails.deny`** | verbotene Pfad-Globs für das deterministische Gate | in DEIN Projekt-Repo: ja |

### `config.yml` — die wichtigsten Schalter
- `tracker.adapter` / `tracker.cmd` — welcher Adapter (linear/github/eigener).
- `repo.base_branch` / `repo.pr_base` — dein Live-/Default-Branch.
- `verify.commands` — was grün sein muss, sonst kein PR/Deploy (z. B. `npm run test`).
- `council.enabled` / `council.members` / `council.confidence_threshold` — Gremium an/aus, Linsen, Schwelle (Default 75).
- `deploy.enabled` — **Master-Schalter für Auto-Deploy** (`false` = klassisch, endet immer am PR).
- `deploy.command` — optionaler Deploy-Befehl nach Merge (leer = deine CI/CD deployt nach Merge selbst).
- `deploy.deployed_state` / `deploy.manual_queue_state` — Tracker-Status nach Deploy bzw. für die Warteschlange.
- `notify.reporter_on_deploy` — Reporter nach Auto-Deploy pingen („umgesetzt — bitte testen").
- `guardrails.max_files_changed` — Obergrenze „minimaler Fix" (Default 12).
- `guardrails.forbidden_keywords` — Stichwörter, bei denen schon die **Klassifikation** eskaliert.
- `mode.plan_only: true` — **Dry-Run**: postet nur einen Plan-Kommentar, schreibt keinen Code.

### Council & Auto-Deploy — wie die 75 %-Schwelle wirkt
Zwei unabhängige Confidence-Achsen, beide müssen ≥ `confidence_threshold` liegen:
1. **Klassifikation** (vor dem Fix): „Ist das ein echter, eng umrissener Bug/Feature?"
2. **Fix-Verifikation** (nach grünen Tests): „Löst das Diff den gemeldeten Fall vollständig?"

`bin/council-decide.sh` aggregiert die JSON-Urteile der Linsen aus
`.sds-state/council/<id>/` und gibt **deterministisch** `AUTODEPLOY` / `MANUAL` /
`REJECT` zurück. Auto-Deploy nur bei `AUTODEPLOY` **und** `deploy.enabled: true`
**und** sauberem Pfad-Gate. Empfehlung zum Vertrauensaufbau: erst mit
`deploy.enabled: false` (nur Warteschlange) fahren, dann scharfschalten.

### `.sds-env` — Secrets
Nur die Variablen deines Adapters füllen. Linear braucht API-Key + Team-UUID +
Poll-/Review-State-UUIDs; GitHub braucht nur `owner/repo` (Auth via `gh`).
State-UUIDs findest du per `query { workflowStates { nodes { id name } } }`.

### `guardrails.deny` — die rote Linie
Glob pro Zeile (gitignore-artig, `**` = beliebige Tiefe). Großzügig sperren —
was hier steht, ändert **kein** Bot. Default deckt Schema, Auth, Secrets,
Migrationen, Infra/Deploy und Lockfiles ab.

---

## Betrieb

Ein einzelner Zyklus ist ein Aufruf:

```
/selfdeveloping-system
```

Getaktet betreiben — zwei Wege:

- **Lokaler Loop (Session-gebunden, empfohlen für DSGVO-sensible Projekte):**
  `/loop 6h /selfdeveloping-system` — läuft, solange deine Claude-Code-Session
  offen ist. Code + Secrets bleiben auf deiner Maschine.
- **Cloud-Routine (überlebt die Session):** `/schedule` — braucht aber, dass
  Repo, `.sds-env` und `gh`-Auth in der Cloud-Umgebung verfügbar sind. Für
  geschützte Daten oft **nicht** erwünscht; bewusst entscheiden.

Jeder Zyklus tut höchstens eine Sache und meldet eine Zeile:
`<id> → fix-PR <url>` · `skipped (<grund>)` · `blocked (<bereich>)` · `nichts zu tun`.

---

## Eigenen Tracker anbinden

Ein Adapter ist ein Skript mit **vier Verben** (`poll`/`get`/`comment`/`move`) —
siehe [`adapters/CONTRACT.md`](adapters/CONTRACT.md). Kopiere `adapters/linear.sh`
als Vorlage, ersetze die API-Aufrufe, halte das Ausgabeformat ein
(`id<TAB>ref<TAB>title`), trage `tracker.cmd` in `config.yml` ein — fertig. Die
Zyklus-Logik bleibt unberührt. Jira, GitLab, Redmine usw. sind so in einer Datei
machbar.

---

## Was „self-developing" hier heißt — und was nicht

In der Forschung (SICA, Darwin Gödel Machine, AlphaEvolve) bezeichnet
„self-improving agent" einen Agenten, der **seinen eigenen Code/Prompts/Tools**
gegen einen automatischen Benchmark umschreibt. **Das ist hier _nicht_ gemeint.**

Hier entwickelt sich das **System** weiter, nicht der Agent: das laufende Produkt
nimmt seine eigenen Bug-/Feature-Reports und korrigiert seinen eigenen Quellcode —
deterministisch eingehegt. Bei hoher Council-Confidence **darf** es autonom
deployen; sonst legt es die Änderung dem Menschen vor. Es ist kein
selbst-evolvierender Agent (er schreibt nicht seinen eigenen Code/Prompt um) — die
Autonomie liegt im **Ausrollen geprüfter Fixes**, nicht in Selbstmodifikation.
Diese Ehrlichkeit ist Absicht: die Sicherheit kommt aus dem engen Aktionsraum,
der deterministischen Schwelle und dem Pfad-Gate mit absolutem Veto — nicht aus
einem Prompt-Versprechen.

---

## Stand der Technik (woraus dieser Skill gelernt hat)

- **Anthropic claude-code-action / auto-fix** — Event-getriebene PR-Fixes; Idee
  des *unabhängigen Safety-Classifiers* → hier als deterministisches Pfad-Gate.
- **GitHub Copilot Coding Agent** — Issue→PR in VM; *PR braucht menschliche
  Approval vor CI/CD* → hier „endet am PR".
- **SWE-agent / mini-swe-agent** — kleiner, auditierbarer Aktionsraum als Guardrail.
- **OpenHands, Sweep, Open SWE** — self-hostbare Issue→PR-Agenten; „funktioniert
  am besten bei eng umrissenen Issues" → hier erzwungen via Klassifikation + Eskalation.
- **Guardrail-Literatur** — die drei wirksamsten Schranken: Pfad-Restriktion,
  read-only-DB, **Branch-Isolation**. Alle drei sind hier eingebaut.

---

## Grenzen & ehrliche Risiken

- **Auto-Deploy ist echte Autonomie.** Mit `deploy.enabled: true` rollt das System
  Änderungen ohne Menschen aus, sobald das Council auf beiden Achsen ≥ Schwelle ist.
  Ein Logikfehler, der baut, Tests grün hält **und** das Gremium überzeugt, kann
  live gehen. Drei Gegengewichte: aussagekräftige Tests, eine konservative
  `confidence_threshold`, und eine **großzügige `guardrails.deny`** (das Pfad-Gate
  hat absolutes Veto). Für sensible Projekte: `deploy.enabled: false` lassen.
- Tests müssen aussagekräftig sein; ohne Coverage sinkt der Schutz — und steigt das Deploy-Risiko.
- Das Council ist nur so gut wie seine Linsen; es ersetzt kein menschliches Review,
  es **rationiert** es (hohe Confidence → autonom, sonst → Warteschlange).
- Der Skill ist für **eng umrissene Bugs und kleine Features** gebaut, nicht für
  Architektur/Produktentscheidungen — solche Tickets werden bewusst eskaliert.
- `gh`/Tracker-Auth, Deploy-Befehl und Branch-Schutzregeln liegen in deiner Verantwortung.

---

## Lizenz

MIT — siehe [LICENSE](LICENSE).
