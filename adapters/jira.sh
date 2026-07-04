#!/usr/bin/env bash
#
# jira.sh — Jira-Cloud-Adapter für den Selfdeveloping-System-Skill.
# Implementiert den Adapter-Vertrag (CONTRACT.md): poll | get | comment | move | notify.
# REST API v3 (Jira Cloud). Beschreibungen/Kommentare sind ADF (Atlassian
# Document Format) — der Adapter extrahiert bzw. baut das JSON transparent.
#
# Liest aus ../.sds-env:
#   SDS_JIRA_URL               https://<org>.atlassian.net — Pflicht
#   SDS_JIRA_EMAIL             Account-E-Mail (Basic Auth) — Pflicht
#   SDS_JIRA_TOKEN             API-Token (id.atlassian.com → Security) — Pflicht
#   SDS_JIRA_PROJECT_KEY       z. B. "SUP" — Pflicht
#   SDS_JIRA_POLL_STATUS       Status, in dem gepollt wird (Default: "To Do")
#   SDS_JIRA_REQUIRED_LABEL    Label(s), komma-separiert = ODER (Default: "bug")
#   SDS_JIRA_OPT_IN_LABEL      optional: zusätzlich gefordertes Label
#   SDS_JIRA_REVIEW_TRANSITION Default-Ziel für `move` ohne Arg (Transition-NAME, z. B. "In Review")
#
# `id` = `ref` = Issue-Key (z. B. SUP-42). `move` führt die benannte Workflow-
# Transition aus. `notify` nennt den Reporter (Jira mailt Reporter/Watcher bei
# Kommentaren ohnehin selbst).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .sds-env ] || { echo "FEHLER: .sds-env fehlt." >&2; exit 1; }
set -a; . ./.sds-env; set +a

: "${SDS_JIRA_URL:?SDS_JIRA_URL fehlt in .sds-env}"
: "${SDS_JIRA_EMAIL:?SDS_JIRA_EMAIL fehlt in .sds-env}"
: "${SDS_JIRA_TOKEN:?SDS_JIRA_TOKEN fehlt in .sds-env}"
: "${SDS_JIRA_PROJECT_KEY:?SDS_JIRA_PROJECT_KEY fehlt in .sds-env}"
POLL_STATUS="${SDS_JIRA_POLL_STATUS:-To Do}"
REQUIRED_LABEL="${SDS_JIRA_REQUIRED_LABEL:-bug}"
OPT_IN_LABEL="${SDS_JIRA_OPT_IN_LABEL:-}"
API="$SDS_JIRA_URL/rest/api/3"
AUTH=(-u "$SDS_JIRA_EMAIL:$SDS_JIRA_TOKEN" -H "Content-Type: application/json")

fetch() {
  local out tries=0
  while [ "$tries" -lt 4 ]; do
    out=$(curl -s --max-time 20 "${AUTH[@]}" "$1" 2>/dev/null) || true
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    tries=$((tries + 1)); sleep 1
  done
  echo "FEHLER: Jira lieferte nach 4 Versuchen keine Antwort." >&2
  return 1
}

send() { curl -s --max-time 20 -X "$1" "${AUTH[@]}" -d "$3" "$2" 2>/dev/null || true; }

# Kommentar-Text → minimales ADF-Dokument
adf_payload() { python3 -c '
import json,sys
paras=[{"type":"paragraph","content":[{"type":"text","text":p}]} for p in sys.argv[1].split("\n\n") if p.strip()]
print(json.dumps({"body":{"type":"doc","version":1,"content":paras or [{"type":"paragraph","content":[]}]}}))' "$1"; }

case "${1:-}" in
  poll)
    JQL=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' \
      "project = \"$SDS_JIRA_PROJECT_KEY\" AND status = \"$POLL_STATUS\" ORDER BY created ASC")
    fetch "$API/search?jql=$JQL&maxResults=50&fields=summary,labels,created" \
      | REQUIRED_LABEL="$REQUIRED_LABEL" OPT_IN_LABEL="$OPT_IN_LABEL" python3 -c '
import json,os,sys
try: d=json.load(sys.stdin)
except Exception as e: sys.stderr.write("JIRA: ungueltige Antwort (%s)\n"%e); sys.exit(1)
if "issues" not in d: sys.stderr.write("JIRA: %s\n"%d); sys.exit(1)
req={x.strip().lower() for x in os.environ["REQUIRED_LABEL"].split(",") if x.strip()}
opt=os.environ.get("OPT_IN_LABEL","").strip().lower()
for n in d["issues"]:
    labels={(l or "").lower() for l in (n["fields"].get("labels") or [])}
    if req and not (labels & req): continue
    if opt and opt not in labels: continue
    print("%s\t%s\t%s" % (n["key"], n["key"], n["fields"]["summary"]))
'
    ;;
  get)
    key="${2:?issue-key fehlt}"
    fetch "$API/issue/$key?fields=summary,description" | python3 -c '
import json,sys
n=json.load(sys.stdin)
if "fields" not in n: sys.stderr.write("JIRA: Ticket nicht gefunden (%s).\n"%n); sys.exit(1)
def adf_text(node):          # ADF → Klartext (rekursiv)
    if node is None: return ""
    if isinstance(node,list): return "".join(adf_text(x) for x in node)
    t=node.get("type")
    if t=="text": return node.get("text","")
    if t=="hardBreak": return "\n"
    inner=adf_text(node.get("content"))
    return inner+"\n" if t in ("paragraph","heading","listItem","codeBlock") else inner
print(n["key"]); print(n["fields"]["summary"]); print("---")
print(adf_text(n["fields"].get("description")).strip())
'
    ;;
  comment)
    ref="${2:?issue-key fehlt}"; body="${3:?text fehlt}"
    send POST "$API/issue/$ref/comment" "$(adf_payload "$body")" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("FEHLER: keine Antwort"); sys.exit(0)
print("OK" if d.get("id") else "FEHLER: %s"%d)'
    ;;
  move)
    ref="${2:?issue-key fehlt}"; state="${3:-${SDS_JIRA_REVIEW_TRANSITION:?state fehlt (Arg oder SDS_JIRA_REVIEW_TRANSITION)}}"
    # Transition-ID zum Namen auflösen (case-insensitiv), dann ausführen.
    tid=$(fetch "$API/issue/$ref/transitions" | python3 -c '
import json,sys
d=json.load(sys.stdin); want=sys.argv[1].strip().lower()
for t in d.get("transitions",[]):
    if t["name"].strip().lower()==want or t["id"]==sys.argv[1]:
        print(t["id"]); break' "$state")
    [ -n "$tid" ] || { echo "FEHLER: Transition '$state' nicht verfügbar für $ref."; exit 1; }
    out=$(send POST "$API/issue/$ref/transitions" "{\"transition\":{\"id\":\"$tid\"}}")
    # Erfolg = leere Antwort (HTTP 204); alles andere ist eine Fehlermeldung.
    [ -z "$out" ] && echo "OK → $state" || echo "FEHLER: $out"
    ;;
  notify)
    ref="${2:?issue-key fehlt}"; body="${3:?text fehlt}"
    name=$(fetch "$API/issue/$ref?fields=reporter" | python3 -c '
import json,sys
n=json.load(sys.stdin); r=(n.get("fields",{}) or {}).get("reporter") or {}
print(r.get("displayName") or "")' 2>/dev/null || true)
    body="${body//\{\{REPORTER_MENTION\}\}/$name}"
    send POST "$API/issue/$ref/comment" "$(adf_payload "$body")" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("FEHLER: keine Antwort"); sys.exit(0)
print("OK" if d.get("id") else "FEHLER: %s"%d)'
    ;;
  *)
    echo "usage: jira.sh {poll | get <key> | comment <key> <text> | move <key> [<transition>] | notify <key> <text>}" >&2; exit 1 ;;
esac
