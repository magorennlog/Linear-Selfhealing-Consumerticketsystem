#!/usr/bin/env bash
#
# guardrail-check.sh — DETERMINISTISCHES Sicherheits-Gate.
#
# Prüft das Diff des aktuellen Branches gegen den Basis-Branch auf:
#   1. verbotene Pfade (Globs aus guardrails.deny) — z. B. Schema, Auth, Migrations
#   2. zu viele geänderte Dateien (Obergrenze → vermutlich kein "minimaler Fix")
#
# Unabhängig vom Plan/Reasoning des Agenten. Der Skill MUSS dieses Skript vor
# `git push`/PR laufen lassen. BLOCK → Branch verwerfen + eskalieren, kein PR.
#
#   guardrail-check.sh <base-branch> [max-files]
#
# Läuft im aktuellen Git-Repo (cwd). guardrails.deny wird relativ zum
# Skript-Verzeichnis gesucht (override: SDS_DENY_FILE). Exit: 0 = PASS, 2 = BLOCK, 1 = Fehler.
# Portabel für Bash 3.2 (kein mapfile): Diff wird direkt nach python3 gepipet.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
DENY_FILE="${SDS_DENY_FILE:-$SKILL_DIR/guardrails.deny}"

BASE="${1:?usage: guardrail-check.sh <base-branch> [max-files]}"
MAX_FILES="${2:-${SDS_MAX_FILES:-12}}"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "FEHLER: kein Git-Repo (cwd=$PWD)." >&2; exit 1; }
[ -f "$DENY_FILE" ] || { echo "FEHLER: Deny-Liste fehlt: $DENY_FILE" >&2; exit 1; }

git diff --name-only "$BASE"...HEAD | DENY_FILE="$DENY_FILE" MAX_FILES="$MAX_FILES" python3 -c '
import sys, os, re

changed = [l.strip() for l in sys.stdin if l.strip()]
deny = []
with open(os.environ["DENY_FILE"]) as f:
    for line in f:
        line = line.split("#",1)[0].strip()
        if line: deny.append(line)

def to_regex(glob):
    # gitignore-artig: ** = beliebige Tiefe, * = innerhalb eines Segments
    g = re.escape(glob.lstrip("/"))
    g = g.replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    # nackter Name darf auch tiefer im Baum matchen
    return re.compile(r"(^|.*/)" + g + r"($|/.*)")

rx = [(d, to_regex(d)) for d in deny]

if not changed:
    print("BLOCK"); print("Keine Änderungen gegenüber Basis (leerer Branch)."); sys.exit(2)

hits = []
for path in changed:
    for raw, r in rx:
        if r.match(path):
            hits.append((path, raw)); break

problems = []
if hits:
    problems.append("Verbotene Pfade berührt:")
    for path, raw in hits:
        problems.append("  - %s  (Regel: %s)" % (path, raw))

maxf = int(os.environ["MAX_FILES"])
if len(changed) > maxf:
    problems.append("Zu viele Dateien geändert: %d > max %d (kein minimaler Fix?)." % (len(changed), maxf))

if problems:
    print("BLOCK"); print("\n".join(problems)); sys.exit(2)
print("PASS: %d Datei(en) geändert, keine verbotenen Pfade." % len(changed))
'
