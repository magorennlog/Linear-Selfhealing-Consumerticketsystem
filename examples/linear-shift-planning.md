# Praxis-Beispiel: Linear + Next.js-Live-System (Auto-Deploy ab 75 %)

Ein typisches Setup, für das dieser Skill gebaut ist: ein Web-Tool
(Next.js + Prisma + Postgres), das auf einem `master = live`-Branch deployt —
jeder Merge geht über einen Auto-Deploy-Cron ~2 min später auf Produktion. Genau
deshalb ist die **Confidence-Schwelle** hier sicherheitskritisch: ein autonomer
Merge ist ein autonomer Deploy, also darf er nur bei hoher Council-Sicherheit und
sauberem Pfad-Gate passieren.

## `config.yml` (Auszug)

```yaml
tracker:
  adapter: linear
  cmd: "adapters/linear.sh"
  review_state: ""            # nutzt SDS_LINEAR_REVIEW_STATE_ID

repo:
  base_branch: master
  branch_prefix: "auto/"
  pr_base: master

verify:
  commands:
    - "npm run test"

council:
  enabled: true
  members: [reproducer, scope-skeptic, security-warden, product-judge]
  confidence_threshold: 75
  floor: 50

deploy:
  enabled: true               # Auto-Deploy scharf — erst nach Vertrauensaufbau!
  confidence_threshold: 75
  command: ""                 # leer: Merge auf master triggert den Deploy-Cron
  deployed_state: ""          # nutzt SDS_LINEAR_DEPLOYED_STATE_ID
  manual_queue_state: ""      # nutzt SDS_LINEAR_MANUAL_QUEUE_STATE_ID

notify:
  reporter_on_deploy: true

guardrails:
  deny_paths_file: "guardrails.deny"
  max_files_changed: 12
  forbidden_keywords: [schema, migration, "ALTER TABLE", auth, login, passwort,
                       security, DSGVO, löschen, payment]
  max_open_auto_prs: 3

output:
  comment_language: de
  state_file: ".sds-state/processed.txt"

mode:
  plan_only: false
```

## `guardrails.deny` (projekt-spezifisch geschärft)

```
**/schema.prisma
prisma/migrations/**
**/business-rules.ts         # sicherheits-/compliance-relevante Kernlogik — nie automatisch
**/auth/**
**/*session*
.env*
deploy*.sh
docker-compose*.yml
```

Die `business-rules.ts`-Zeile ist der Kern: dort steckt Logik mit rechtlichem/
Compliance-Bezug (z. B. arbeitszeitrechtliche Regeln). Ein Bot fasst sie nie an —
solche Tickets eskalieren deterministisch, selbst wenn sie als „Bug" gelabelt sind
und selbst bei 100 % Council-Confidence (das Pfad-Gate hat absolutes Veto).

## Betrieb

```
/loop 6h /selfdeveloping-system
```

Lokaler 6-Stunden-Loop, session-gebunden. Linear-Creds (`.sds-env`) und das Repo
bleiben auf der Entwickler-Maschine — passend zu DSGVO-Anforderungen. Eine
Cloud-Routine wäre möglich, würde aber Repo + Secrets in die Cloud verlagern; hier
bewusst nicht gewählt.

## Typischer Zyklus-Ausgang

- `ENG-42 → deployed https://github.com/owner/repo/pull/57 (classify 88%, verify 91%)` — Council auf beiden Achsen sicher, Gate PASS → autonom ausgerollt, Reporter benachrichtigt.
- `ENG-43 → queued https://github.com/owner/repo/pull/58 (verify 63% < 75%)` — Fix da, aber Council unsicher → manuelle Freigabe-Warteschlange.
- `ENG-44 → skipped (vage: kein reproduzierbares Soll/Ist)` — Rückfrage als Kommentar.
- `ENG-45 → blocked (Schema)` — Beschreibung wollte ein DB-Feld; eskaliert.
- `ENG-46 → rejected (council)` — Refuter fand einen fehlenden Edge-Case; Branch verworfen.
- `nichts zu tun` — Backlog leer.

## Vertrauensaufbau-Empfehlung

1. Start mit `deploy.enabled: false` → alles geht in die Warteschlange; du siehst
   die Council-Scores in den PRs und kalibrierst `confidence_threshold`.
2. Erst wenn die Autonomie-Vorschläge über Wochen zuverlässig sind: `deploy.enabled: true`.
