#!/usr/bin/env bash
#
# report.sh — Metriken-Report über die bisherige Arbeit des Systems.
#
# Liest die lokale Audit-Spur und beantwortet: Wie oft wurde gefixt, eskaliert,
# geblockt? Wie sicher war das Council? Und (best effort, via gh): Wie viele der
# manuell vorgelegten PRs hat ein Mensch tatsächlich gemergt — der Feedback-Loop,
# der zeigt, ob die Confidence-Schwelle richtig kalibriert ist.
#
#   report.sh [state-file] [council-dir]
#
# Defaults: <skill>/.sds-state/processed.txt und <skill>/.sds-state/council.
# Nur lesend; braucht bash/python3, optional gh für die Merge-Quote.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
STATE="${1:-$SKILL_DIR/.sds-state/processed.txt}"
COUNCIL="${2:-$SKILL_DIR/.sds-state/council}"

[ -f "$STATE" ] || { echo "Noch keine Daten: $STATE fehlt (das System ist noch nicht gelaufen)."; exit 0; }

echo "── Selfdeveloping System — Report ─────────────────────────"

# ---- 1) Ausgänge zählen (Zeilenformat: <id> <status>[:<info>] <timestamp>) ----
python3 - "$STATE" <<'PY'
import sys, collections
counts = collections.Counter(); total = 0
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) < 2: continue
    total += 1
    status = parts[1].split(":", 1)[0]
    counts[status] += 1
print("Zyklen mit Ergebnis: %d" % total)
order = ["deployed", "pr", "queued", "planned", "skipped", "failed", "blocked", "rejected"]
label = {"deployed": "autonom deployt", "pr": "PR erstellt (v0.1)", "queued": "manuelle Warteschlange",
         "planned": "geplant (dry-run)", "skipped": "übersprungen/eskaliert",
         "failed": "Tests rot", "blocked": "Gate-BLOCK", "rejected": "Council-REJECT"}
for k in order:
    if counts.get(k): print("  %-28s %d" % (label.get(k, k) + ":", counts[k]))
for k, v in counts.items():
    if k not in order: print("  %-28s %d" % (k + ":", v))
done = counts.get("deployed", 0) + counts.get("pr", 0) + counts.get("queued", 0)
if total: print("Fix-Quote (Fix erstellt / Zyklen): %d%%" % round(100 * done / total))
# Eskalationsgründe (skipped:<grund>)
reasons = collections.Counter()
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) >= 2 and parts[1].startswith(("skipped:", "failed:", "blocked:", "rejected:")):
        reasons[parts[1]] += 1
if reasons:
    print("Häufigste Eskalations-/Block-Gründe:")
    for r, n in reasons.most_common(5): print("  %-28s %d" % (r + ":", n))
PY

# ---- 2) Council-Confidences aggregieren ----
if [ -d "$COUNCIL" ]; then
python3 - "$COUNCIL" <<'PY'
import sys, os, glob, json
base = sys.argv[1]
cls, ver = [], []
for fp in glob.glob(os.path.join(base, "*", "*.json")):
    try: v = json.load(open(fp))
    except Exception: continue
    c = v.get("confidence")
    if not isinstance(c, (int, float)): continue
    (cls if os.path.basename(fp).startswith("classify-") else ver).append(float(c))
if cls or ver:
    print("Council (über alle Tickets):")
    if cls: print("  Klassifikation: Ø %.0f%% (%d Urteile)" % (sum(cls)/len(cls), len(cls)))
    if ver: print("  Fix-Verifikation: Ø %.0f%% (%d Urteile)" % (sum(ver)/len(ver), len(ver)))
PY
fi

# ---- 3) Feedback-Loop: was hat der Mensch mit den queued-PRs gemacht? ----
# (best effort — nur für GitHub-PR-URLs und nur wenn gh verfügbar/eingeloggt ist)
if command -v gh >/dev/null 2>&1; then
  merged=0; closed=0; open=0
  while read -r url; do
    st=$(gh pr view "$url" --json state --jq .state 2>/dev/null) || continue
    case "$st" in
      MERGED) merged=$((merged+1));;
      CLOSED) closed=$((closed+1));;
      OPEN)   open=$((open+1));;
    esac
  done < <(grep -Eo 'queued:https://github[^ ]+' "$STATE" 2>/dev/null | cut -d: -f2- | sort -u)
  if [ $((merged + closed + open)) -gt 0 ]; then
    echo "Manuelle Warteschlange (menschliches Urteil über queued-PRs):"
    echo "  gemergt: $merged · abgelehnt (closed): $closed · noch offen: $open"
    if [ $((merged + closed)) -gt 0 ]; then
      echo "  Annahme-Quote: $(( 100 * merged / (merged + closed) ))%  ← Kalibrierungs-Signal für die Schwelle"
    fi
  fi
fi

echo "───────────────────────────────────────────────────────────"
