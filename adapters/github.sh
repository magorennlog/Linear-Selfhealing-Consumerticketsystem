#!/usr/bin/env bash
#
# github.sh — GitHub-Issues-Adapter für den Selfdeveloping-System-Skill.
# Implementiert den Adapter-Vertrag (CONTRACT.md): poll | get | comment | move.
# Nutzt die `gh` CLI (muss installiert + `gh auth login` erfolgt sein).
#
# Liest aus ../.sds-env:
#   SDS_GITHUB_REPO            owner/repo (Pflicht — der Adapter läuft im Skill-Dir, nicht im Ziel-Repo)
#   SDS_GITHUB_REQUIRED_LABEL  Label(s), die ein Issue tragen muss; komma-separiert = ODER
#                              (Default: "bug" — für dieses Tool typisch "bug,feature")
#   SDS_GITHUB_OPT_IN_LABEL    optional: zusätzlich gefordertes Label (z. B. "auto-ok")
#
# GitHub kennt keine Workflow-States wie Linear → `move` wird als Label-Setzen
# interpretiert (z. B. review_state="in-review"). `id` und `ref` sind beide die
# Issue-Nummer; `id` wird als "#<n>" ausgegeben (für Branch-/PR-Namen).
# `notify` @mentiont den Issue-Autor (Reporter), damit er gepingt wird.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -f .sds-env ] || { echo "FEHLER: .sds-env fehlt." >&2; exit 1; }
set -a; . ./.sds-env; set +a
command -v gh >/dev/null || { echo "FEHLER: gh CLI nicht gefunden." >&2; exit 1; }

: "${SDS_GITHUB_REPO:?SDS_GITHUB_REPO fehlt in .sds-env (owner/repo)}"
REQUIRED_LABEL="${SDS_GITHUB_REQUIRED_LABEL:-bug}"
OPT_IN_LABEL="${SDS_GITHUB_OPT_IN_LABEL:-}"

case "${1:-}" in
  poll)
    # ODER über komma-separierte required_label → in Python filtern (gh --label ANDet).
    gh issue list -R "$SDS_GITHUB_REPO" --state open --json number,title,createdAt,labels --limit 100 \
      | REQUIRED_LABEL="$REQUIRED_LABEL" OPT_IN_LABEL="$OPT_IN_LABEL" python3 -c '
import json,os,sys
try: ns=json.load(sys.stdin)
except Exception as e: sys.stderr.write("GITHUB: ungueltige Antwort (%s)\n"%e); sys.exit(1)
req={x.strip().lower() for x in os.environ["REQUIRED_LABEL"].split(",") if x.strip()}
opt=os.environ.get("OPT_IN_LABEL","").strip().lower()
def labels(n): return {l["name"].lower() for l in n["labels"]}
elig=[n for n in ns if (labels(n) & req) and (not opt or opt in labels(n))]
for n in sorted(elig, key=lambda x:x["createdAt"]):
    print("#%s\t%s\t%s" % (n["number"], n["number"], n["title"]))
'
    ;;
  get)
    num="${2:?id/nummer fehlt}"; num="${num#\#}"
    gh issue view "$num" -R "$SDS_GITHUB_REPO" --json number,title,body | python3 -c '
import json,sys
n=json.load(sys.stdin); print(n["number"]); print(n["title"]); print("---"); print(n["body"] or "")
'
    ;;
  comment)
    ref="${2:?ref/nummer fehlt}"; ref="${ref#\#}"; body="${3:?text fehlt}"
    gh issue comment "$ref" -R "$SDS_GITHUB_REPO" --body "$body" >/dev/null && echo "OK" || echo "FEHLER: gh issue comment fehlgeschlagen"
    ;;
  move)
    ref="${2:?ref/nummer fehlt}"; ref="${ref#\#}"; state="${3:-${SDS_GITHUB_REVIEW_LABEL:?state/label fehlt (Arg oder SDS_GITHUB_REVIEW_LABEL)}}"
    gh issue edit "$ref" -R "$SDS_GITHUB_REPO" --add-label "$state" >/dev/null && echo "OK → Label '$state'" || echo "FEHLER: gh issue edit fehlgeschlagen"
    ;;
  notify)
    ref="${2:?ref/nummer fehlt}"; ref="${ref#\#}"; body="${3:?text fehlt}"
    # Autor (Reporter) auflösen und @mentionen; scheitert das, normaler Kommentar.
    author=$(gh issue view "$ref" -R "$SDS_GITHUB_REPO" --json author -q '.author.login' 2>/dev/null || true)
    mention=""; [ -n "$author" ] && mention="@$author"
    body="${body//\{\{REPORTER_MENTION\}\}/$mention}"
    gh issue comment "$ref" -R "$SDS_GITHUB_REPO" --body "$body" >/dev/null && echo "OK" || echo "FEHLER: gh issue comment (notify) fehlgeschlagen"
    ;;
  *)
    echo "usage: github.sh {poll | get <id> | comment <ref> <text> | move <ref> [<label>] | notify <ref> <text>}" >&2; exit 1 ;;
esac
