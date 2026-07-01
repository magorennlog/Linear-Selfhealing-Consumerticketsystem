#!/usr/bin/env bash
#
# council-decide.sh — DETERMINISTISCHE Schwellen-Entscheidung aus Council-Urteilen.
#
# Das Council (mehrere LLM-Linsen) schreibt strukturierte JSON-Urteile in ein
# Verzeichnis (siehe templates/council-rubric.md). DIESES Skript aggregiert sie
# und entscheidet — unabhängig vom Agent-Reasoning. Der Agent liefert Zahlen,
# die Schwellen-Logik lebt hier. (Gleiche Idee wie bin/guardrail-check.sh.)
#
#   council-decide.sh <verdict-dir> <threshold> <phase>   # phase: classify | deploy
#
# classify  liest classify-*.json   → PROCEED (0) | ESCALATE (3)
# deploy    liest classify-*.json + verify-*.json
#           → AUTODEPLOY (0) | MANUAL (3) | REJECT (2)
#
# Exit: 0 = grünes Licht, 3 = an Mensch (Warteschlange/Eskalation), 2 = harte
# Ablehnung (Branch verwerfen), 1 = Fehler. Optional: SDS_COUNCIL_FLOOR (Default 50).
set -euo pipefail

DIR="${1:?usage: council-decide.sh <verdict-dir> <threshold> <phase>}"
THRESHOLD="${2:?threshold (z. B. 75) fehlt}"
PHASE="${3:?phase fehlt (classify | deploy)}"
FLOOR="${SDS_COUNCIL_FLOOR:-50}"

[ -d "$DIR" ] || { echo "FEHLER: Verdict-Verzeichnis fehlt: $DIR" >&2; exit 1; }

DIR="$DIR" THRESHOLD="$THRESHOLD" PHASE="$PHASE" FLOOR="$FLOOR" python3 -c '
import json, os, sys, glob

d         = os.environ["DIR"]
threshold = float(os.environ["THRESHOLD"])
phase     = os.environ["PHASE"]
floor     = float(os.environ["FLOOR"])

def load(pattern):
    out = []
    for fp in sorted(glob.glob(os.path.join(d, pattern))):
        try:
            with open(fp) as f:
                out.append((os.path.basename(fp), json.load(f)))
        except Exception as e:
            print("FEHLER: %s nicht lesbar (%s)" % (fp, e)); sys.exit(1)
    return out

def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0

def conf(v):
    try:
        return float(v.get("confidence"))
    except (TypeError, ValueError):
        print("FEHLER: Urteil ohne numerische confidence: %s" % v); sys.exit(1)

cls = load("classify-*.json")
if len(cls) < 3:
    print("MANUAL" if phase == "deploy" else "ESCALATE")
    print("Zu wenige Council-Urteile (%d < 3) — keine autonome Freigabe." % len(cls))
    sys.exit(3)

# --- Phase: classify ---
invalid = [n for n, v in cls if not v.get("is_valid")]
cls_conf = [conf(v) for _, v in cls]
cls_mean = mean(cls_conf)
cls_min  = min(cls_conf)

if phase == "classify":
    if invalid:
        print("ESCALATE")
        print("Mitglied(er) halten den Report fuer ungueltig/heikel: %s" % ", ".join(invalid))
        sys.exit(3)
    if cls_mean < threshold:
        print("ESCALATE")
        print("Klassifikations-Confidence %.0f < Schwelle %.0f." % (cls_mean, threshold))
        sys.exit(3)
    # Mehrheits-Typ (bug/feature) als Hinweis ausgeben
    types = [v.get("type", "bug") for _, v in cls]
    top = max(set(types), key=types.count)
    print("PROCEED")
    print("type=%s classify_confidence=%.0f (min %.0f, %d Stimmen)" % (top, cls_mean, cls_min, len(cls)))
    sys.exit(0)

# --- Phase: deploy ---
if phase == "deploy":
    ver = load("verify-*.json")
    if len(ver) < 1:
        print("MANUAL"); print("Keine Verifikations-Urteile vorhanden."); sys.exit(3)

    refuted = [n for n, v in ver if not v.get("fix_resolves")]
    if refuted:
        print("REJECT")
        print("Fix vom Council widerlegt: %s" % ", ".join(refuted))
        sys.exit(2)

    ver_conf = [conf(v) for _, v in ver]
    ver_mean = mean(ver_conf); ver_min = min(ver_conf)

    reasons = []
    if invalid:                  reasons.append("Klassifikation nicht einstimmig (%s)" % ", ".join(invalid))
    if cls_mean < threshold:     reasons.append("classify %.0f < %.0f" % (cls_mean, threshold))
    if ver_mean < threshold:     reasons.append("verify %.0f < %.0f"   % (ver_mean, threshold))
    if cls_min  < floor:         reasons.append("ein classify-Votum < floor %.0f" % floor)
    if ver_min  < floor:         reasons.append("ein verify-Votum < floor %.0f"   % floor)

    if reasons:
        print("MANUAL")
        print("In die manuelle Warteschlange: " + "; ".join(reasons) + ".")
        sys.exit(3)

    print("AUTODEPLOY")
    print("classify=%.0f verify=%.0f (beide >= %.0f, floor %.0f) — autonome Freigabe."
          % (cls_mean, ver_mean, threshold, floor))
    sys.exit(0)

print("FEHLER: unbekannte phase %r (classify | deploy)" % phase); sys.exit(1)
'
