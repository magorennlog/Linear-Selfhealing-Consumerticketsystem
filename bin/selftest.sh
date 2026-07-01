#!/usr/bin/env bash
#
# selftest.sh — Fixture-Tests für die zwei DETERMINISTISCHEN Gates.
#
# Beweist, dass die Sicherheits-Logik wirklich greift — unabhängig vom Agenten:
#   - bin/guardrail-check.sh : verbotene Pfade / Datei-Obergrenze / leerer Branch
#   - bin/council-decide.sh  : 75%-Schwelle, floor, Einstimmigkeit, Refuter-Veto
#
# Braucht nur bash, git, python3. Legt alles in Temp-Verzeichnissen an, fasst
# dein Projekt nicht an.  Aufruf:  bash bin/selftest.sh   (Exit 0 = alle grün)
set -uo pipefail
SDS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
# assert_exit <erwarteter-code> <beschreibung> -- <befehl…>
assert_exit() {
  local want="$1" desc="$2"; shift 3
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" = "$want" ] && ok "$desc (exit $got)" || bad "$desc — erwartet exit $want, war $got"
}

echo "→ council-decide.sh"
CD="$SDS/bin/council-decide.sh"
VD="$(mktemp -d)"
mk(){ printf '%s' "$2" > "$VD/$1"; }
reset_dir(){ rm -f "$VD"/*.json; }

# --- classify ---
reset_dir
mk classify-a.json '{"member":"a","phase":"classify","is_valid":true,"type":"bug","confidence":85,"rationale":"x"}'
mk classify-b.json '{"member":"b","phase":"classify","is_valid":true,"type":"bug","confidence":80,"rationale":"x"}'
mk classify-c.json '{"member":"c","phase":"classify","is_valid":true,"type":"bug","confidence":78,"rationale":"x"}'
assert_exit 0 "classify: 3x valide & hoch → PROCEED" -- bash "$CD" "$VD" 75 classify

mk classify-c.json '{"member":"c","phase":"classify","is_valid":false,"type":"bug","confidence":20,"rationale":"auth"}'
assert_exit 3 "classify: ein Mitglied is_valid=false → ESCALATE" -- bash "$CD" "$VD" 75 classify

mk classify-c.json '{"member":"c","phase":"classify","is_valid":true,"type":"bug","confidence":40,"rationale":"x"}'
assert_exit 3 "classify: Mittelwert < Schwelle → ESCALATE" -- bash "$CD" "$VD" 75 classify

reset_dir
mk classify-a.json '{"member":"a","phase":"classify","is_valid":true,"type":"bug","confidence":90,"rationale":"x"}'
mk classify-b.json '{"member":"b","phase":"classify","is_valid":true,"type":"bug","confidence":90,"rationale":"x"}'
assert_exit 3 "classify: < 3 Urteile → ESCALATE (keine autonome Freigabe)" -- bash "$CD" "$VD" 75 classify

# --- deploy ---
reset_dir
mk classify-a.json '{"member":"a","phase":"classify","is_valid":true,"type":"bug","confidence":85,"rationale":"x"}'
mk classify-b.json '{"member":"b","phase":"classify","is_valid":true,"type":"bug","confidence":82,"rationale":"x"}'
mk classify-c.json '{"member":"c","phase":"classify","is_valid":true,"type":"bug","confidence":80,"rationale":"x"}'
mk verify-a.json '{"member":"a","phase":"verify","fix_resolves":true,"confidence":90,"rationale":"x"}'
mk verify-r.json '{"member":"r","phase":"verify","fix_resolves":true,"confidence":85,"rationale":"x"}'
assert_exit 0 "deploy: beide Achsen hoch → AUTODEPLOY" -- bash "$CD" "$VD" 75 deploy

mk verify-a.json '{"member":"a","phase":"verify","fix_resolves":true,"confidence":60,"rationale":"x"}'
mk verify-r.json '{"member":"r","phase":"verify","fix_resolves":true,"confidence":55,"rationale":"x"}'
assert_exit 3 "deploy: verify-Mittelwert < Schwelle → MANUAL" -- bash "$CD" "$VD" 75 deploy

mk verify-a.json '{"member":"a","phase":"verify","fix_resolves":true,"confidence":95,"rationale":"x"}'
mk verify-r.json '{"member":"r","phase":"verify","fix_resolves":true,"confidence":40,"rationale":"x"}'
assert_exit 3 "deploy: ein Votum < floor 50 → MANUAL" -- bash "$CD" "$VD" 75 deploy

mk verify-r.json '{"member":"r","phase":"verify","fix_resolves":false,"confidence":30,"rationale":"widerlegt"}'
assert_exit 2 "deploy: Refuter fix_resolves=false → REJECT" -- bash "$CD" "$VD" 75 deploy
rm -rf "$VD"

echo "→ guardrail-check.sh"
GC="$SDS/bin/guardrail-check.sh"
REPO="$(mktemp -d)"; DENY="$(mktemp)"
printf '%s\n' '**/schema.prisma' '**/auth/**' '.env*' > "$DENY"
(
  cd "$REPO"
  git init -q; git config user.email t@t.t; git config user.name t
  mkdir -p src; echo 'a' > src/app.js; git add -A; git commit -qm base
  BASE="$(git branch --show-current)"
  echo "$BASE" > .sds-base   # an die Tests weiterreichen
)
BASE="$(cat "$REPO/.sds-base")"; rm -f "$REPO/.sds-base"

run_gc(){ ( cd "$REPO" && SDS_DENY_FILE="$DENY" bash "$GC" "$BASE" "${1:-12}" ) ; }

# PASS: kleiner Diff, erlaubter Pfad
( cd "$REPO"; git checkout -q -b feat-ok; echo 'b' >> src/app.js; git add -A; git commit -qm ok )
assert_exit 0 "guardrail: 1 erlaubte Datei → PASS" -- run_gc 12

# BLOCK: verbotener Pfad
( cd "$REPO"; git checkout -q "$BASE"; git checkout -q -b feat-deny
  mkdir -p prisma; echo 'x' > prisma/schema.prisma; git add -A; git commit -qm deny )
assert_exit 2 "guardrail: schema.prisma berührt → BLOCK" -- run_gc 12

# BLOCK: zu viele Dateien
( cd "$REPO"; git checkout -q "$BASE"; git checkout -q -b feat-many
  for i in $(seq 1 13); do echo x > "src/f$i.js"; done; git add -A; git commit -qm many )
assert_exit 2 "guardrail: 13 Dateien > max 12 → BLOCK" -- run_gc 12
assert_exit 0 "guardrail: dieselben 13 mit max 20 → PASS" -- run_gc 20

# BLOCK: leerer Branch (kein Diff gegen base)
( cd "$REPO"; git checkout -q "$BASE"; git checkout -q -b feat-empty )
assert_exit 2 "guardrail: leerer Branch → BLOCK" -- run_gc 12
rm -rf "$REPO" "$DENY"

echo
echo "Ergebnis: $PASS grün, $FAIL rot."
[ "$FAIL" = 0 ] && { echo "✅ alle Gates verhalten sich wie spezifiziert."; exit 0; } || { echo "❌ mindestens ein Gate weicht ab."; exit 1; }
