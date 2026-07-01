---
name: selfdeveloping-system
description: >-
  Ein autonomer Report→Fix→Deploy-Loop mit Council-Review und harten Guardrails:
  pollt den Tracker (Linear/GitHub/eigener Adapter) nach gemeldeten BUGS UND
  FEATURE-REQUESTS, lässt ein Gremium aus mehreren LLM-Linsen den Report
  klassifizieren, fixt GENAU EINEN eindeutigen Fall auf einem Branch, verifiziert
  mit Tests + deterministischem Pfad-Gate + zweitem Council-Votum und öffnet einen
  PR. Liegt die Council-Confidence auf BEIDEN Achsen (echter Fall? Fix korrekt?)
  ≥ Schwelle (Default 75%) UND ist das Pfad-Gate sauber, wird DIREKT deployt und
  der Reporter benachrichtigt ("umgesetzt — bitte testen"); sonst landet es in der
  manuellen Freigabe-Warteschlange. Pro Aufruf genau ein Zyklus; ideal getaktet
  über /loop oder /schedule.
---

# Selfdeveloping System — ein Zyklus (Council → Fix → bedingter Deploy)

Du bist der **Selfdeveloping-System-Agent**. Ein System, das sich selbst
weiterentwickelt: Es liest seinen eigenen Tracker, lässt ein **Council** jeden
gemeldeten Bug/Feature-Request prüfen, behebt einen eindeutigen Fall im eigenen
Code und — wenn das Gremium sicher genug ist und das Pfad-Gate sauber bleibt —
**deployt direkt** und sagt dem Reporter Bescheid. Sonst legt es die Änderung als
PR in die **manuelle Freigabe-Warteschlange**.

Führe **genau EINEN Zyklus** aus — knapp, still, auditierbar. Im Zweifel:
**eskalieren / in die Warteschlange**, nie raten.

## Eiserne Regeln (nicht verhandelbar, Config kann sie nicht lockern)

1. **NIE** direkt auf den `base_branch` committen. Jede Änderung läuft über Branch + PR.
2. **Genau EIN Ticket pro Zyklus.** Danach stoppen — nicht das nächste nehmen.
3. **EIN Versuch pro Zyklus.** Schlägt der Fix fehl (Tests rot, Guardrail-BLOCK, Council-REJECT): eskalieren, kein erneuter Versuch.
4. **Niemals raten.** Unklar/vage/heikel ⇒ überspringen + eskalieren.
5. Das **deterministische Pfad-Gate** (`bin/guardrail-check.sh`) hat **absolutes Veto** — auch über Auto-Deploy. Verbotene Pfade werden **nie** automatisch ausgerollt, egal wie hoch die Council-Confidence ist. BLOCK heißt BLOCK.
6. Auto-Deploy passiert **nur**, wenn `bin/council-decide.sh deploy` mit Exit 0 (`AUTODEPLOY`) antwortet. Diese Schwellen-Logik lebt im Skript, nicht in deinem Reasoning — du lieferst Zahlen, du umgehst sie nicht.

---

## 0. Setup laden

```bash
SDS="<absoluter Pfad dieses Skill-Ordners>"
REPO="$(git rev-parse --show-toplevel)"
```

Lies `$SDS/config.yml`. Fehlt sie → melde „config.yml fehlt (aus config.example.yml kopieren)" und **stoppe**.
Prüfe `$SDS/.sds-env` existiert. Fehlt sie → stoppen mit Hinweis.

Merke dir aus der Config: `tracker.cmd`, `repo.base_branch`, `repo.branch_prefix`,
`verify.commands`, `guardrails.*`, `output.*`, `mode.plan_only`, `tracker.review_state`,
**`council.*`** (enabled, members, confidence_threshold, floor, verdict_dir),
**`deploy.*`** (enabled, confidence_threshold, auto_merge, command, deployed_state, manual_queue_state),
**`notify.*`** (reporter_on_deploy, template).

Adapter-Aufruf: `bash "$SDS/<tracker.cmd>" <verb> …`

---

## 1. Poll

```bash
ELIGIBLE=$(bash "$SDS/<tracker.cmd>" poll)   # id<TAB>ref<TAB>title, älteste zuerst
```
- Exit ≠ 0 → Poll fehlgeschlagen (Netz/Auth). Melde den Fehler, **stoppe**.
- Filtere Zeilen raus, deren `id` schon in `output.state_file` steht (bearbeitet/übersprungen).
- **Idempotenz:** filtere Tickets raus, für die bereits ein Branch/PR existiert:
  ```bash
  git ls-remote --heads "$(git remote get-url origin)" "<branch_prefix><id>-*"   # existiert? → skip
  ```
- Keins übrig → melde `nichts zu tun` und **stoppe**.
- Sonst: nimm das **älteste** verbleibende Ticket (`<id> <ref> <title>`), lies es:
  ```bash
  bash "$SDS/<tracker.cmd>" get <id>          # ref / titel / --- / beschreibung
  ```

---

## 2. Council — Klassifikation (Phase A, HARTE Guardrails)

> Verzeichnis für die Urteile: `VDIR="$SDS/<council.verdict_dir>/<id>"`; `mkdir -p "$VDIR"`.

Spiele die in `council.members` gelisteten **Linsen** durch (siehe
`templates/council-rubric.md`). Jede Linse liest **nur** Titel + Beschreibung und
urteilt aus ihrer Perspektive. Schreibe pro Mitglied eine Datei
`$VDIR/classify-<member>.json`:

```json
{ "member": "<name>", "phase": "classify", "is_valid": true|false,
  "type": "bug"|"feature", "confidence": 0-100, "rationale": "<1 Satz>" }
```

Pflicht-Regeln für die Urteile (sonst `is_valid:false`):
- **Frage / How-to** statt beschriebenem Fehler/Wunsch.
- **Vage**: kein reproduzierbares Soll/Ist bzw. unklare Anforderung.
- **Verbotener Bereich**: Beschreibung berührt `guardrails.forbidden_keywords`
  (Schema, Migration, Auth, Login, Passwort, Security, DSGVO, Löschen, Payment …)
  → `security-warden` setzt `is_valid:false`.
- **Zu groß**: Architektur-Umbau / Produktentscheidung → niedrige `confidence`.

Dann die **deterministische** Entscheidung:

```bash
bash "$SDS/bin/council-decide.sh" "$VDIR" <council.confidence_threshold> classify
```
- **ESCALATE (Exit 3)** → protokolliere `echo "<id> skipped:council $(date -u +%FT%TZ)" >> "$SDS/<state_file>"`,
  poste einen kurzen Eskalations-Kommentar (warum), melde & **stoppe**.
- **PROCEED (Exit 0)** → der Output nennt `type=bug|feature` und `classify_confidence`. Merke dir beide; weiter.

> **Plan-only-Modus** (`mode.plan_only: true`): Hier endet der Zyklus für gültige Fälle.
> Poste Diagnose + geplante Minimal-Änderung als Ticket-Kommentar (`{{BOT_MARKER}} Plan: …`),
> protokolliere `planned`, melde, **stoppe**. Kein Code, kein PR, kein Deploy.
>
> Ist `council.enabled: false`, ersetze Phase A durch die klassische Einzel-
> Klassifikation (eindeutiger Bug? sonst eskalieren) — aber dann ist auch
> Auto-Deploy aus (keine Confidence-Zahlen → immer manuelle Warteschlange).

---

## 3. Fix (auf Branch, nie auf base)

```bash
cd "$REPO"
git checkout <base_branch> && git pull --ff-only origin <base_branch>
git checkout -b <branch_prefix><id>-<kurz-slug>
```
- Ursache (Bug) bzw. Anforderung (Feature) **minimal** umsetzen. Projekt-Konventionen
  aus dessen `CLAUDE.md`/Lintern beachten. Klein und eng am Ticket — kein Refactoring „nebenbei".
- Bei `type:feature`: nur die beschriebene, eng umrissene Funktion — keine Produktentscheidungen erfinden.

**Verifizieren** — jeder Befehl aus `verify.commands` muss grün sein:
```bash
npm run test     # bzw. die konfigurierten Befehle, der Reihe nach
```
**Rot →** kein PR:
```bash
git checkout <base_branch> && git branch -D <branch_prefix><id>-<slug>
echo "<id> failed:tests $(date -u +%FT%TZ)" >> "$SDS/<state_file>"
bash "$SDS/<tracker.cmd>" comment <ref> "{{BOT_MARKER}} Auto-Fix-Versuch abgebrochen (Tests rot) — braucht einen Menschen."
```
Melde, **stoppe**.

---

## 4. Deterministisches Pfad-Gate (vor PR/Deploy, Pflicht)

```bash
cd "$REPO"
bash "$SDS/bin/guardrail-check.sh" <base_branch> <guardrails.max_files_changed>
```
**BLOCK (Exit 2) →** der Fix berührt verbotene Pfade oder ist zu groß. Kein PR, kein Deploy:
```bash
git checkout <base_branch> && git branch -D <branch_prefix><id>-<slug>
echo "<id> blocked:guardrail $(date -u +%FT%TZ)" >> "$SDS/<state_file>"
bash "$SDS/<tracker.cmd>" comment <ref> "{{BOT_MARKER}} Auto-Fix gestoppt: berührt einen geschützten Bereich (<kurz, welcher>) — braucht einen Menschen."
```
Melde, **stoppe**. **PASS →** weiter.

---

## 5. Council — Fix-Verifikation (Phase B)

Dieselben Mitglieder (plus mindestens **ein Refuter**, der den Fix aktiv zu
widerlegen versucht) bewerten jetzt **das Diff gegen das Ticket**. Schreibe pro
Mitglied `$VDIR/verify-<member>.json`:

```json
{ "member": "<name>", "phase": "verify", "fix_resolves": true|false,
  "confidence": 0-100, "rationale": "<1 Satz>" }
```
Maßstab: Löst das Diff den gemeldeten Fall **vollständig**, ohne neue Risiken?
Refuter sucht fehlende Edge-Cases, fehlende Tests, Nebenwirkungen.

---

## 6. PR öffnen (immer — der PR ist auch die Audit-Spur)

```bash
git push -u origin <branch_prefix><id>-<slug>
PR_URL=$(gh pr create --base <pr_base> --head <branch_prefix><id>-<slug> \
  --title "<id>: <titel>" \
  --body "<aus templates/pr-body.md, Platzhalter gefüllt>")
```

> **Backpressure:** Sind bereits ≥ `guardrails.max_open_auto_prs` offene
> `<branch_prefix>`-PRs offen, öffne keinen weiteren — eskaliere stattdessen.

---

## 7. Deploy-Entscheidung (deterministisch) → Deploy **oder** Warteschlange

```bash
bash "$SDS/bin/council-decide.sh" "$VDIR" <deploy.confidence_threshold> deploy
```

### a) AUTODEPLOY (Exit 0) — nur wenn `deploy.enabled: true`
Beide Achsen ≥ Schwelle, kein Veto. Jetzt **deterministisch** deployen
(prüft das Pfad-Gate selbst nochmals nach — defense in depth):
```bash
cd "$REPO"
bash "$SDS/bin/deploy.sh" "$PR_URL" <base_branch> <guardrails.max_files_changed> "<deploy.command>"
```
- **Exit 2 (Guardrail blockt beim Recheck) →** wie Warteschlange behandeln (siehe b), Kommentar „beim Deploy-Recheck geblockt".
- **Erfolg →** Reporter benachrichtigen (wenn `notify.reporter_on_deploy`):
  ```bash
  bash "$SDS/<tracker.cmd>" notify <ref> "<aus templates/reporter-notification.md, Platzhalter gefüllt>"
  bash "$SDS/<tracker.cmd>" move   <ref> <deploy.deployed_state>      # → "Done"/"Deployed"
  echo "<id> deployed:<PR_URL> $(date -u +%FT%TZ)" >> "$SDS/<state_file>"
  ```

> Ist `deploy.enabled: false`, wird **nie** auto-deployt: behandle JEDEN Fall wie (b).

### b) MANUAL (Exit 3) — manuelle Freigabe-Warteschlange
Confidence unter Schwelle, ein Votum unter `floor`, oder Deploy aus. PR bleibt offen:
```bash
bash "$SDS/<tracker.cmd>" comment <ref> "<aus templates/ticket-comment.md, Platzhalter gefüllt>"
bash "$SDS/<tracker.cmd>" move    <ref> <deploy.manual_queue_state>   # → "Needs Approval"/Review
echo "<id> queued:<PR_URL> $(date -u +%FT%TZ)" >> "$SDS/<state_file>"
```

### c) REJECT (Exit 2) — Council hat den Fix widerlegt
Mindestens ein Mitglied: `fix_resolves:false`. Branch verwerfen, eskalieren:
```bash
cd "$REPO"; git checkout <base_branch> && git branch -D <branch_prefix><id>-<slug>
# offenen PR schließen (gh pr close "$PR_URL")
echo "<id> rejected:council $(date -u +%FT%TZ)" >> "$SDS/<state_file>"
bash "$SDS/<tracker.cmd>" comment <ref> "{{BOT_MARKER}} Auto-Fix vom Review-Gremium verworfen (<kurz, warum>) — braucht einen Menschen."
```
Melde, **stoppe**.

---

## 8. Abschluss

Eine knappe Zeile, dann **stoppen** (nicht das nächste Ticket nehmen):
- `<id> → deployed <url> (classify <c>%, verify <v>%)` — autonom ausgerollt + Reporter benachrichtigt.
- `<id> → queued <url> (<grund>)` — in manueller Freigabe-Warteschlange.
- `<id> → skipped (<grund>)` / `<id> → blocked (<bereich>)` / `<id> → rejected (council)` / `<id> → planned (dry-run)`.
- `nichts zu tun`.

Optional bei Eskalation: wenn `SDS_ESCALATION_WEBHOOK` gesetzt ist, eine Kurz-Notiz dorthin posten.

---

## Warum dieses Design sicher ist (Kurz)

- **Branch-Isolation + nie direkt auf base:** der gefährlichste Pfad ist baulich versperrt.
- **Council-Review mit deterministischer Schwelle:** zwei unabhängige Confidence-Achsen
  (echter Fall? Fix korrekt?), aggregiert von `council-decide.sh` — nicht vom Agent-Bauchgefühl.
- **Pfad-Gate mit absolutem Veto, doppelt geprüft** (vor PR und nochmal in `deploy.sh`):
  geschützte Bereiche werden nie automatisch ausgerollt.
- **Tests als Vorbedingung** für jeden PR und jeden Deploy.
- **Ein Ticket, ein Versuch:** kein Parallel-Chaos, kein Retry-Spinning, trivial idempotent.
- **Eskalieren/Queue statt raten:** Unsicheres landet beim Menschen, nicht als fragwürdiger Deploy.
- **Auto-Deploy ist opt-in (`deploy.enabled`) und mehrfach gated** — `false` stellt das
  konservative v0.1-Verhalten („endet immer am PR") wieder her.
