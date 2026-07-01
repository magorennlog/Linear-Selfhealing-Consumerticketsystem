#!/usr/bin/env bash
#
# deploy.sh — DETERMINISTISCHER Deploy-Executor (nur nach Council-Freigabe).
#
# Wird vom Skill NUR aufgerufen, wenn council-decide.sh "deploy" AUTODEPLOY (0)
# ergab. Trotzdem prueft dieses Skript die rote Linie SELBST noch einmal nach
# (defense in depth): das Pfad-Gate hat auch hier absolutes Veto. Verbotene
# Pfade werden NIE auto-deployt — egal wie hoch die Council-Confidence war.
#
#   deploy.sh <pr-url-or-number> <base-branch> <max-files> [deploy-cmd]
#
# Schritte:
#   1. Guardrail-Recheck des PR-Branches gegen base  → BLOCK = Abbruch, kein Merge
#   2. PR mergen (squash, Branch loeschen)            → via gh
#   3. optionaler Deploy-Befehl                        → leer = CI/CD uebernimmt nach Merge
#
# Exit: 0 = deployt, 2 = vom Guardrail blockiert (kein Merge), 1 = Fehler.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR="${1:?usage: deploy.sh <pr> <base-branch> <max-files> [deploy-cmd]}"
BASE="${2:?base-branch fehlt}"
MAX_FILES="${3:?max-files fehlt}"
DEPLOY_CMD="${4:-}"

command -v gh >/dev/null || { echo "FEHLER: gh CLI nicht gefunden." >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "FEHLER: kein Git-Repo (cwd=$PWD)." >&2; exit 1; }

# 1) Defense in depth: dasselbe Pfad-Gate noch einmal, jetzt unmittelbar vor Merge.
#    Der PR-Head muss lokal als aktueller Branch ausgecheckt sein (der Skill ist
#    nach dem Fix auf dem Auto-Branch). Wir pruefen HEAD gegen base.
echo "→ Guardrail-Recheck vor Deploy …"
if ! bash "$HERE/guardrail-check.sh" "$BASE" "$MAX_FILES"; then
  echo "ABBRUCH: Guardrail-Gate blockt — kein Auto-Merge, kein Deploy. An Mensch." >&2
  exit 2
fi

# 2) Mergen. Squash + Branch loeschen; --auto faellt auf sofort-merge zurueck,
#    wenn keine Branch-Protection-Checks anstehen.
echo "→ Merge PR $PR (squash) …"
gh pr merge "$PR" --squash --delete-branch \
  || { echo "FEHLER: gh pr merge fehlgeschlagen (Branch-Protection? Konflikt?)." >&2; exit 1; }

# 3) Optionaler Deploy-Befehl. Leer ⇒ Annahme: Merge auf base triggert deine CI/CD.
if [ -n "$DEPLOY_CMD" ]; then
  echo "→ Deploy-Befehl: $DEPLOY_CMD"
  bash -c "$DEPLOY_CMD" || { echo "FEHLER: Deploy-Befehl fehlgeschlagen (PR ist bereits gemergt!)." >&2; exit 1; }
else
  echo "→ Kein Deploy-Befehl konfiguriert — CI/CD uebernimmt nach Merge auf $BASE."
fi

echo "DEPLOYED: $PR"
