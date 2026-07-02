# Consumer-Setup mit Supabase — projektübergreifendes Ticket-Tracking

Endnutzer (keine Entwickler!) melden Bugs und Wünsche über ein simples Formular.
Alle Reports landen in **einer zentralen Supabase-Tabelle** — beliebig viele
Projekte in einer DB, unterschieden über die `project`-Spalte. Pro Projekt läuft
eine Skill-Instanz, die nur „ihre" Tickets pollt.

```
Endnutzer → report-form.html (anon-Key, RLS: nur INSERT)
                 │
                 ▼
     Supabase: sds_tickets (project='shop') ─┐
               sds_tickets (project='app')  ─┤  eine DB, viele Projekte
               sds_tickets (project='api')  ─┘
                 │                                    ┌─ Council → Fix → Gates
                 ├── Skill-Instanz im shop-Repo  ─────┤
                 ├── Skill-Instanz im app-Repo   ─────┤  je Repo: SDS_SUPABASE_PROJECT
                 └── Skill-Instanz im api-Repo   ─────┘
```

## Setup (≈ 15 Minuten)

1. **Supabase-Projekt** anlegen (supabase.com, Free Tier reicht).
2. **Schema einspielen:** `examples/supabase-schema.sql` im SQL-Editor ausführen.
   Legt `sds_tickets` + `sds_comments` an, inkl. RLS: der öffentliche anon-Key
   darf **nur Tickets einfügen** — nicht lesen, nicht ändern.
3. **Keys holen** (Settings → API): `anon`-Key fürs Formular, `service_role`-Key
   für den Adapter. **Der service_role-Key gehört ausschließlich in `.sds-env`.**
4. **Formular einbauen:** `examples/report-form.html` kopieren, die drei
   CONFIG-Werte setzen (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `PROJECT`), hosten
   oder in die App einbetten. Honeypot-Spamschutz ist eingebaut.
5. **Skill konfigurieren** (im Projekt-Repo):
   - `.sds-env`: den `SDS_SUPABASE_*`-Block ausfüllen (siehe `.sds-env.example`).
   - `config.yml`: `tracker.adapter: supabase`, `tracker.cmd: "adapters/supabase.sh"`,
     `deploy.manual_queue_state: needs-approval`, `deploy.deployed_state: deployed`.
6. **Smoke-Test:** `bash adapters/supabase.sh poll` (leer = ok), Testticket übers
   Formular absenden, nochmal pollen → eine Zeile `SB-1 …`.
7. **Betrieb:** `/loop 6h /selfdeveloping-system` im jeweiligen Projekt-Repo.

## Reporter-Benachrichtigung („umgesetzt — bitte testen")

`notify` schreibt immer einen Kommentar an das Ticket (Audit-Spur). Für echte
**E-Mails** an den Reporter: `SDS_SUPABASE_NOTIFY_WEBHOOK` auf einen Endpunkt
zeigen lassen, der Mails verschickt — z. B. eine Supabase Edge Function mit
Resend/Postmark, oder n8n/Make. Der Webhook bekommt:

```json
{ "email": "...", "name": "...", "ticket_id": 42, "project": "shop", "text": "<fertige Nachricht>" }
```

## ⚠️ Policy für anonyme Reporter (wichtig)

Consumer-Reports sind **untrusted Input von Fremden** — das Prompt-Injection-
Bedrohungsmodell (siehe README) gilt hier voll. Empfehlung:

- **`deploy.enabled: false`** für Consumer-Projekte: alles läuft durch die
  manuelle Freigabe-Warteschlange; das Council + die Gates filtern trotzdem
  schon Unfug, Vages und Injection-Versuche heraus.
- Auto-Deploy nur, wenn ein Mensch Tickets vorher sichtet und ein Opt-in-Label
  setzt (`SDS_SUPABASE_OPT_IN_LABEL`, z. B. `auto-ok`) — dann pollt der Skill
  nur diese. Anonymer Input + Auto-Deploy ist die gefährlichste Kombination.

## Projektübergreifende Auswertung

Alles liegt in einer DB — Auswertung ist ein SQL-Query:

```sql
select project, status, count(*) from sds_tickets
group by project, status order by project;
```

Eskalationsgründe, Council-Confidences und Deploy-Historie stehen als
Bot-Kommentare in `sds_comments` (author `bot`/`bot-notify`) und im
`state_file`/`.sds-state/council/` jeder Skill-Instanz.
