#!/usr/bin/env bash
#
# linear.sh — Linear-Adapter für den Selfdeveloping-System-Skill.
# Implementiert den Adapter-Vertrag (siehe CONTRACT.md): poll | get | comment | move.
#
# Liest Secrets aus ../.sds-env (gitignored, chmod 600):
#   SDS_LINEAR_API_KEY        Personal API Key (Settings → Security & access → API)
#   SDS_LINEAR_TEAM_ID        Team-UUID (URL beim Öffnen des Teams, oder via API)
#   SDS_LINEAR_POLL_STATE_ID  Workflow-State-UUID, in dem gepollt wird (z. B. "Backlog"/"Todo")
#   SDS_LINEAR_REVIEW_STATE_ID Workflow-State-UUID für `move` nach PR (z. B. "In Review")
#   SDS_LINEAR_REQUIRED_LABEL Label(s), die ein Ticket tragen muss; komma-separiert = ODER
#                             (Default: "bug" — für dieses Tool typisch "bug,feature")
#   SDS_LINEAR_OPT_IN_LABEL   optional: zusätzlich gefordertes Label (z. B. "auto-ok"); leer = aus
#
# JSON-Payloads baut python3 (sicher gegen Sonderzeichen). curl ist gegen
# transiente Leerantworten gehärtet: erst eine NICHT-leere Antwort gilt.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .sds-env ] || { echo "FEHLER: .sds-env fehlt (aus .sds-env.example kopieren, Werte eintragen, chmod 600)." >&2; exit 1; }
set -a; . ./.sds-env; set +a

: "${SDS_LINEAR_API_KEY:?SDS_LINEAR_API_KEY fehlt in .sds-env}"
: "${SDS_LINEAR_TEAM_ID:?SDS_LINEAR_TEAM_ID fehlt in .sds-env}"
REQUIRED_LABEL="${SDS_LINEAR_REQUIRED_LABEL:-bug}"
OPT_IN_LABEL="${SDS_LINEAR_OPT_IN_LABEL:-}"
API="https://api.linear.app/graphql"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# Bis zu 4 Versuche; nur eine nicht-leere Antwort gilt. Bleibt alles leer →
# Exit 1 + Klartext (statt Python-Traceback / falschem "nichts zu tun").
gql() {
  local out tries=0
  while [ "$tries" -lt 4 ]; do
    out=$(curl -s --max-time 20 --retry 2 --retry-delay 1 -X POST "$API" \
      -H "Content-Type: application/json" -H "Authorization: $SDS_LINEAR_API_KEY" \
      -d @"$1" 2>/dev/null) || true
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    tries=$((tries + 1)); sleep 1
  done
  echo "FEHLER: Linear-API lieferte nach 4 Versuchen keine Antwort." >&2
  return 1
}

case "${1:-}" in
  poll)
    : "${SDS_LINEAR_POLL_STATE_ID:?SDS_LINEAR_POLL_STATE_ID fehlt in .sds-env}"
    cat > "$TMP" <<JSON
{"query":"query { issues(filter: { team: { id: { eq: \"$SDS_LINEAR_TEAM_ID\" } }, state: { id: { eq: \"$SDS_LINEAR_POLL_STATE_ID\" } } }, first: 50) { nodes { identifier id title createdAt labels { nodes { name } } } } }"}
JSON
    gql "$TMP" | REQUIRED_LABEL="$REQUIRED_LABEL" OPT_IN_LABEL="$OPT_IN_LABEL" python3 -c '
import json,os,sys
raw=sys.stdin.read()
if not raw.strip():
    sys.stderr.write("LINEAR: leere Antwort (Netz/Timeout) — Poll fehlgeschlagen, KEIN Ergebnis.\n"); sys.exit(1)
d=json.loads(raw)
if "errors" in d: sys.stderr.write("LINEAR: %s\n"%d["errors"]); sys.exit(1)
req={x.strip().lower() for x in os.environ["REQUIRED_LABEL"].split(",") if x.strip()}
opt=os.environ.get("OPT_IN_LABEL","").strip().lower()
ns=d["data"]["issues"]["nodes"]
def labels(n): return {l["name"].lower() for l in n["labels"]["nodes"]}
elig=[n for n in ns if (labels(n) & req) and (not opt or opt in labels(n))]
for n in sorted(elig, key=lambda x:x["createdAt"]):
    print("%s\t%s\t%s" % (n["identifier"], n["id"], n["title"]))
'
    ;;
  get)
    num="${2:?id/nummer fehlt}"; num="${num#\#}"; num="${num##*-}"  # akzeptiert "ENG-42", "42" oder "#42"
    cat > "$TMP" <<JSON
{"query":"query { issues(filter: { team: { id: { eq: \"$SDS_LINEAR_TEAM_ID\" } }, number: { eq: $num } }) { nodes { id identifier title description } } }"}
JSON
    gql "$TMP" | python3 -c '
import json,sys
ns=json.load(sys.stdin)["data"]["issues"]["nodes"]
if not ns: sys.stderr.write("LINEAR: Ticket nicht gefunden.\n"); sys.exit(1)
n=ns[0]; print(n["id"]); print(n["title"]); print("---"); print(n["description"] or "")
'
    ;;
  comment)
    ref="${2:?ref/uuid fehlt}"; body="${3:?text fehlt}"
    python3 -c 'import json,sys; print(json.dumps({"query":"mutation($i:String!,$b:String!){commentCreate(input:{issueId:$i,body:$b}){success}}","variables":{"i":sys.argv[1],"b":sys.argv[2]}}))' "$ref" "$body" > "$TMP"
    gql "$TMP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("OK" if d.get("data",{}).get("commentCreate",{}).get("success") else "FEHLER: %s"%d)'
    ;;
  move)
    ref="${2:?ref/uuid fehlt}"; state="${3:-${SDS_LINEAR_REVIEW_STATE_ID:?state fehlt (Arg oder SDS_LINEAR_REVIEW_STATE_ID)}}"
    python3 -c 'import json,sys; print(json.dumps({"query":"mutation($i:String!,$s:String!){issueUpdate(id:$i,input:{stateId:$s}){success issue{state{name}}}}","variables":{"i":sys.argv[1],"s":sys.argv[2]}}))' "$ref" "$state" > "$TMP"
    gql "$TMP" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("issueUpdate",{}); print("OK → %s"%r["issue"]["state"]["name"] if r.get("success") else "FEHLER: %s"%d)'
    ;;
  notify)
    ref="${2:?ref/uuid fehlt}"; body="${3:?text fehlt}"
    # Reporter (Issue-Creator) auflösen; Name in {{REPORTER_MENTION}} einsetzen.
    # Linear benachrichtigt Subscriber (inkl. Creator) bei jedem Kommentar.
    python3 -c 'import json,sys; print(json.dumps({"query":"query($i:String!){issue(id:$i){creator{displayName name}}}","variables":{"i":sys.argv[1]}}))' "$ref" > "$TMP"
    name=$(gql "$TMP" | python3 -c 'import json,sys
try:
    c=json.load(sys.stdin).get("data",{}).get("issue",{}).get("creator") or {}
    print("@"+c["displayName"] if c.get("displayName") else "")
except Exception: print("")' 2>/dev/null || true)
    body="${body//\{\{REPORTER_MENTION\}\}/$name}"
    python3 -c 'import json,sys; print(json.dumps({"query":"mutation($i:String!,$b:String!){commentCreate(input:{issueId:$i,body:$b}){success}}","variables":{"i":sys.argv[1],"b":sys.argv[2]}}))' "$ref" "$body" > "$TMP"
    gql "$TMP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("OK" if d.get("data",{}).get("commentCreate",{}).get("success") else "FEHLER: %s"%d)'
    ;;
  *)
    echo "usage: linear.sh {poll | get <id> | comment <ref> <text> | move <ref> [<stateId>] | notify <ref> <text>}" >&2; exit 1 ;;
esac
