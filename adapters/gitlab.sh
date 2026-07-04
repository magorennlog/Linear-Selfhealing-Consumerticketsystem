#!/usr/bin/env bash
#
# gitlab.sh — GitLab-Issues-Adapter für den Selfdeveloping-System-Skill.
# Implementiert den Adapter-Vertrag (CONTRACT.md): poll | get | comment | move | notify.
# REST API v4; funktioniert mit gitlab.com und self-hosted.
#
# Liest aus ../.sds-env:
#   SDS_GITLAB_TOKEN           Personal Access Token (Scope: api) — Pflicht
#   SDS_GITLAB_PROJECT         Projekt-Pfad ("gruppe/repo") oder numerische ID — Pflicht
#   SDS_GITLAB_URL             Default: https://gitlab.com
#   SDS_GITLAB_REQUIRED_LABEL  Label(s), komma-separiert = ODER (Default: "bug")
#   SDS_GITLAB_OPT_IN_LABEL    optional: zusätzlich gefordertes Label
#   SDS_GITLAB_REVIEW_LABEL    Default-Ziel für `move` ohne Arg (z. B. "in-review")
#
# GitLab hat keine Workflow-States → `move` setzt ein Label (wie github.sh).
# `id` = "#<iid>", `ref` = iid. `notify` @mentiont den Issue-Autor.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .sds-env ] || { echo "FEHLER: .sds-env fehlt." >&2; exit 1; }
set -a; . ./.sds-env; set +a

: "${SDS_GITLAB_TOKEN:?SDS_GITLAB_TOKEN fehlt in .sds-env}"
: "${SDS_GITLAB_PROJECT:?SDS_GITLAB_PROJECT fehlt in .sds-env (gruppe/repo oder ID)}"
BASE_URL="${SDS_GITLAB_URL:-https://gitlab.com}"
REQUIRED_LABEL="${SDS_GITLAB_REQUIRED_LABEL:-bug}"
OPT_IN_LABEL="${SDS_GITLAB_OPT_IN_LABEL:-}"
PROJ="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SDS_GITLAB_PROJECT")"
API="$BASE_URL/api/v4/projects/$PROJ"
HDR=(-H "PRIVATE-TOKEN: $SDS_GITLAB_TOKEN" -H "Content-Type: application/json")

# GET mit Retry (leere Antwort = Netzproblem, nie "nichts zu tun")
fetch() {
  local out tries=0
  while [ "$tries" -lt 4 ]; do
    out=$(curl -s --max-time 20 "${HDR[@]}" "$1" 2>/dev/null) || true
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    tries=$((tries + 1)); sleep 1
  done
  echo "FEHLER: GitLab lieferte nach 4 Versuchen keine Antwort." >&2
  return 1
}

send() { curl -s --max-time 20 -X "$1" "${HDR[@]}" -d "$3" "$2" 2>/dev/null || true; }

case "${1:-}" in
  poll)
    fetch "$API/issues?state=opened&per_page=100&order_by=created_at&sort=asc" \
      | REQUIRED_LABEL="$REQUIRED_LABEL" OPT_IN_LABEL="$OPT_IN_LABEL" python3 -c '
import json,os,sys
try: d=json.load(sys.stdin)
except Exception as e: sys.stderr.write("GITLAB: ungueltige Antwort (%s)\n"%e); sys.exit(1)
if isinstance(d,dict): sys.stderr.write("GITLAB: %s\n"%d); sys.exit(1)
req={x.strip().lower() for x in os.environ["REQUIRED_LABEL"].split(",") if x.strip()}
opt=os.environ.get("OPT_IN_LABEL","").strip().lower()
def labels(n): return {(l or "").lower() for l in (n.get("labels") or [])}
for n in d:
    if req and not (labels(n) & req): continue
    if opt and opt not in labels(n): continue
    print("#%s\t%s\t%s" % (n["iid"], n["iid"], n["title"]))
'
    ;;
  get)
    num="${2:?id/iid fehlt}"; num="${num#\#}"
    fetch "$API/issues/$num" | python3 -c '
import json,sys
n=json.load(sys.stdin)
if "iid" not in n: sys.stderr.write("GITLAB: Ticket nicht gefunden (%s).\n"%n); sys.exit(1)
print(n["iid"]); print(n["title"]); print("---"); print(n.get("description") or "")
'
    ;;
  comment)
    ref="${2:?ref/iid fehlt}"; ref="${ref#\#}"; body="${3:?text fehlt}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"body":sys.argv[1]}))' "$body")
    send POST "$API/issues/$ref/notes" "$payload" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("FEHLER: keine Antwort"); sys.exit(0)
print("OK" if isinstance(d,dict) and d.get("id") else "FEHLER: %s"%d)'
    ;;
  move)
    ref="${2:?ref/iid fehlt}"; ref="${ref#\#}"; state="${3:-${SDS_GITLAB_REVIEW_LABEL:?state/label fehlt (Arg oder SDS_GITLAB_REVIEW_LABEL)}}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"add_labels":sys.argv[1]}))' "$state")
    send PUT "$API/issues/$ref" "$payload" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("FEHLER: keine Antwort"); sys.exit(0)
print("OK → Label \x27%s\x27"%sys.argv[1] if isinstance(d,dict) and d.get("iid") else "FEHLER: %s"%d)' "$state"
    ;;
  notify)
    ref="${2:?ref/iid fehlt}"; ref="${ref#\#}"; body="${3:?text fehlt}"
    author=$(fetch "$API/issues/$ref" | python3 -c '
import json,sys
n=json.load(sys.stdin); a=(n.get("author") or {})
print("@"+a["username"] if a.get("username") else "")' 2>/dev/null || true)
    body="${body//\{\{REPORTER_MENTION\}\}/$author}"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"body":sys.argv[1]}))' "$body")
    send POST "$API/issues/$ref/notes" "$payload" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("FEHLER: keine Antwort"); sys.exit(0)
print("OK" if isinstance(d,dict) and d.get("id") else "FEHLER: %s"%d)'
    ;;
  *)
    echo "usage: gitlab.sh {poll | get <id> | comment <ref> <text> | move <ref> [<label>] | notify <ref> <text>}" >&2; exit 1 ;;
esac
