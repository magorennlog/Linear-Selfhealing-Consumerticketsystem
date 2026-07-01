# Changelog

Alle nennenswerten Änderungen an diesem Skill. Format lose nach
[Keep a Changelog](https://keepachangelog.com/), Versionierung nach SemVer.

## [0.2.0] — 2026-06-30
### Hinzugefügt
- **Council-Review** (STORM- / LLM-Council-Prinzip): mehrere Linsen
  (`reproducer`, `scope-skeptic`, `security-warden`, `product-judge`, `refuter`)
  bewerten jeden Report vor dem Fix (Klassifikation) und das Diff nach dem Fix
  (Verifikation) per strukturiertem JSON. `templates/council-rubric.md`.
- **`bin/council-decide.sh`** — deterministischer Schwellen-Entscheider, aggregiert
  die JSON-Urteile zu `PROCEED/ESCALATE` bzw. `AUTODEPLOY/MANUAL/REJECT`. Die
  75 %-Logik lebt im Skript, nicht im Agent-Reasoning.
- **Bedingter Auto-Deploy**: liegt die Council-Confidence auf beiden Achsen
  (echter Fall? Fix korrekt?) ≥ Schwelle und ist das Pfad-Gate sauber, mergt +
  deployt `bin/deploy.sh` autonom — sonst manuelle Freigabe-Warteschlange.
  `bin/deploy.sh` prüft das Pfad-Gate vor dem Merge **erneut** (defense in depth).
- **Reporter-Benachrichtigung** nach Deploy via neues Adapter-Verb `notify`
  (@mention des Erstellers). `templates/reporter-notification.md`.
- **Feature-Requests** zusätzlich zu Bugs: `required_label` jetzt komma-separiert
  (ODER), der Council bestimmt den Typ. Adapter-`poll` entsprechend erweitert.
- **`bin/install.sh`** — idempotentes Ein-Befehl-Setup (Vorlagen kopieren, chmod,
  `.sds-state/` anlegen, Voraussetzungen prüfen).
- Config-Sektionen `council`, `deploy`, `notify`; neue `.sds-env`-Variablen für
  Deployed-/Manual-Queue-States.

### Geändert
- `never_merge`/`never_deploy` sind **keine** harten Invarianten mehr, sondern über
  `deploy.enabled` steuerbar (Default `false` = v0.1-Verhalten). Iron-Rules,
  Pfad-Gate-Veto, „1 Ticket / 1 Versuch" und „nie direkt auf base" bleiben hart.
- `SKILL.md` auf den Zyklus Poll → Council-Classify → Fix → Gate → Council-Verify
  → PR → Deploy-Entscheidung umgebaut. README/Templates/Adapter-Vertrag aktualisiert.

## [0.1.0] — 2026-06-30
### Hinzugefügt
- Erster veröffentlichbarer Stand. Destilliert aus einem produktiven
  Ticket-Fix-Agenten (Linear → PR) eines Live-Web-Systems.
- `SKILL.md`: config-getriebener Ein-Zyklus-Loop (Poll → Klassifizieren → Fix →
  Verifizieren → deterministisches Gate → PR → Kommentar/Status).
- Tracker-Adapter-Vertrag (`adapters/CONTRACT.md`) + Adapter für **Linear**
  (GraphQL, gehärtet gegen Leerantworten) und **GitHub Issues** (`gh`).
- `bin/guardrail-check.sh`: deterministisches Pfad-Gate gegen `guardrails.deny`,
  unabhängig vom Agent-Plan; prüft auch die Datei-Obergrenze.
- Config-Schema (`config.example.yml`), Secrets-Vorlage (`.sds-env.example`),
  Deny-Listen-Vorlage (`guardrails.deny.example`).
- PR-/Kommentar-Templates, Dry-Run-Modus (`plan_only`), Idempotenz über
  Branch-Existenz + `state_file`, Eskalations-Pfad statt Raten.
- Praxis-Beispiel `examples/linear-shift-planning.md`.
