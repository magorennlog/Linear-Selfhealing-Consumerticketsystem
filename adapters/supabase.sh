#!/usr/bin/env bash
#
# supabase.sh — Supabase-Adapter für den Selfdeveloping-System-Skill.
# Implementiert den Adapter-Vertrag (CONTRACT.md): poll | get | comment | move | notify.
#
# Gedacht als CONSUMER-Eingang: Endnutzer melden Bugs/Wünsche über ein simples
# Formular (examples/report-form.html) in eine zentrale Supabase-Tabelle — auch
# projektübergreifend (eine DB, `project`-Spalte, eine Skill-Instanz pro Projekt).
# Schema + RLS: examples/supabase-schema.sql · Setup: examples/supabase-consumer.md
#
# Liest aus ../.sds-env:
#   SDS_SUPABASE_URL             https://<projekt>.supabase.co (Pflicht)
#   SDS_SUPABASE_SERVICE_KEY     service_role-Key (Pflicht — NUR serverseitig, nie ins Formular!)
#   SDS_SUPABASE_PROJECT         Projekt-Slug, den diese Instanz bedient (Pflicht, a-z0-9-)
#   SDS_SUPABASE_TICKETS_TABLE   Default: sds_tickets
#   SDS_SUPABASE_COMMENTS_TABLE  Default: sds_comments
#   SDS_SUPABASE_POLL_STATUS     Status, in dem gepollt wird (Default: open)
#   SDS_SUPABASE_REVIEW_STATUS   Default-Ziel für `move` ohne Arg (Default: in-review)
#   SDS_SUPABASE_REQUIRED_LABEL  optional, komma-separiert = ODER; leer = alle Tickets
#   SDS_SUPABASE_OPT_IN_LABEL    optional: zusätzlich gefordertes Label
#   SDS_SUPABASE_NOTIFY_WEBHOOK  optional: POST {email,name,ticket_id,project,text} für
#                                E-Mail-Versand (Edge Function / n8n / Make …)
#
# `id` = "SB-<n>" (Branch-/PR-Namen), `ref` = numerische Ticket-ID.
# Wie linear.sh gegen leere Antworten gehärtet: erst eine NICHT-leere Antwort gilt.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .sds-env ] || { echo "FEHLER: .sds-env fehlt (aus .sds-env.example kopieren)." >&2; exit 1; }
set -a; . ./.sds-env; set +a

: "${SDS_SUPABASE_URL:?SDS_SUPABASE_URL fehlt in .sds-env}"
: "${SDS_SUPABASE_SERVICE_KEY:?SDS_SUPABASE_SERVICE_KEY fehlt in .sds-env}"
: "${SDS_SUPABASE_PROJECT:?SDS_SUPABASE_PROJECT fehlt in .sds-env}"
TICKETS="${SDS_SUPABASE_TICKETS_TABLE:-sds_tickets}"
COMMENTS="${SDS_SUPABASE_COMMENTS_TABLE:-sds_comments}"
POLL_STATUS="${SDS_SUPABASE_POLL_STATUS:-open}"
REQUIRED_LABEL="${SDS_SUPABASE_REQUIRED_LABEL:-}"
OPT_IN_LABEL="${SDS_SUPABASE_OPT_IN_LABEL:-}"
API="$SDS_SUPABASE_URL/rest/v1"
HDR=(-H "apikey: $SDS_SUPABASE_SERVICE_KEY" -H "Authorization: Bearer $SDS_SUPABASE_SERVICE_KEY" -H "Content-Type: application/json")

# GET mit Retry: PostgREST antwortet auf "keine Treffer" mit "[]", nie mit leer.
# Leer = Netz/Timeout → bis zu 4 Versuche, sonst Exit 1 (kein falsches "nichts zu tun").
fetch() {
  local out tries=0
  while [ "$tries" -lt 4 ]; do
    out=$(curl -s --max-time 20 "${HDR[@]}" "$1" 2>/dev/null) || true
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    tries=$((tries + 1)); sleep 1
  done
  echo "FEHLER: Supabase lieferte nach 4 Versuchen keine Antwort." >&2
  return 1
}

# POST/PATCH mit return=representation: Erfolg ⇔ Antwort ist nicht-leeres JSON-Array.
send() {
  curl -s --max-time 20 -X "$1" "${HDR[@]}" -H "Prefer: return=representation" -d "$3" "$2" 2>/dev/null || true
}

ok_row() { python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("FEHLER: keine/ungueltige Antwort"); sys.exit(0)
if isinstance(d,list) and d: print(sys.argv[1] if len(sys.argv)>1 else "OK")
else: print("FEHLER: %s"%d)' "$@"; }

num_of() { local n="${1:?id fehlt}"; n="${n#SB-}"; n="${n#\#}"; printf '%s' "$n"; }

case "${1:-}" in
  poll)
    fetch "$API/$TICKETS?select=id,title,labels,created_at&project=eq.$SDS_SUPABASE_PROJECT&status=eq.$POLL_STATUS&order=created_at.asc&limit=50" \
      | REQUIRED_LABEL="$REQUIRED_LABEL" OPT_IN_LABEL="$OPT_IN_LABEL" python3 -c '
import json,os,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception as e: sys.stderr.write("SUPABASE: ungueltige Antwort (%s)\n"%e); sys.exit(1)
if isinstance(d,dict): sys.stderr.write("SUPABASE: %s\n"%d); sys.exit(1)   # PostgREST-Fehlerobjekt
req={x.strip().lower() for x in os.environ.get("REQUIRED_LABEL","").split(",") if x.strip()}
opt=os.environ.get("OPT_IN_LABEL","").strip().lower()
def labels(n): return {(l or "").lower() for l in (n.get("labels") or [])}
for n in d:
    if req and not (labels(n) & req): continue
    if opt and opt not in labels(n): continue
    print("SB-%s\t%s\t%s" % (n["id"], n["id"], n["title"]))
'
    ;;
  get)
    num="$(num_of "${2:-}")"
    fetch "$API/$TICKETS?id=eq.$num&select=id,title,description,type" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if not (isinstance(d,list) and d): sys.stderr.write("SUPABASE: Ticket nicht gefunden.\n"); sys.exit(1)
n=d[0]; print(n["id"]); print(n["title"]); print("---"); print(n.get("description") or "")
'
    ;;
  comment)
    ref="$(num_of "${2:-}")"; body="${3:?text fehlt}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"ticket_id":int(sys.argv[1]),"body":sys.argv[2],"author":"bot"}))' "$ref" "$body")
    send POST "$API/$COMMENTS" "$payload" | ok_row
    ;;
  move)
    ref="$(num_of "${2:-}")"; state="${3:-${SDS_SUPABASE_REVIEW_STATUS:-in-review}}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"status":sys.argv[1]}))' "$state")
    send PATCH "$API/$TICKETS?id=eq.$ref" "$payload" | ok_row "OK → $state"
    ;;
  notify)
    ref="$(num_of "${2:-}")"; body="${3:?text fehlt}"
    info=$(fetch "$API/$TICKETS?id=eq.$ref&select=reporter_name,reporter_email,title")
    mention=$(printf '%s' "$info" | python3 -c '
import json,sys
d=json.load(sys.stdin)
n=(d[0] if isinstance(d,list) and d else {})
print(n.get("reporter_name") or n.get("reporter_email") or "")')
    body="${body//\{\{REPORTER_MENTION\}\}/$mention}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"ticket_id":int(sys.argv[1]),"body":sys.argv[2],"author":"bot-notify"}))' "$ref" "$body")
    res=$(send POST "$API/$COMMENTS" "$payload" | ok_row)
    # Optionaler E-Mail-Kanal: Webhook bekommt alles, was er zum Versand braucht.
    # Shared Secret (x-sds-secret) schützt die öffentliche Function-URL vor Missbrauch
    # — siehe examples/notify-edge-function.ts.
    if [ -n "${SDS_SUPABASE_NOTIFY_WEBHOOK:-}" ]; then
      hook=$(printf '%s' "$info" | python3 -c '
import json,sys,os
d=json.load(sys.stdin); n=(d[0] if isinstance(d,list) and d else {})
print(json.dumps({"email":n.get("reporter_email"),"name":n.get("reporter_name"),
                  "ticket_id":int(sys.argv[1]),"project":os.environ["SDS_SUPABASE_PROJECT"],
                  "text":sys.argv[2]}))' "$ref" "$body")
      curl -s --max-time 20 -X POST -H "Content-Type: application/json" \
        ${SDS_SUPABASE_NOTIFY_SECRET:+-H "x-sds-secret: $SDS_SUPABASE_NOTIFY_SECRET"} \
        -d "$hook" "$SDS_SUPABASE_NOTIFY_WEBHOOK" >/dev/null 2>&1 \
        || echo "WARNUNG: Notify-Webhook nicht erreichbar (Kommentar wurde gesetzt)." >&2
    fi
    echo "$res"
    ;;
  *)
    echo "usage: supabase.sh {poll | get <id> | comment <ref> <text> | move <ref> [<status>] | notify <ref> <text>}" >&2; exit 1 ;;
esac
