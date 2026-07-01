#!/usr/bin/env bash
#
# install.sh — Ein-Befehl-Setup des Selfdeveloping-System-Skills in DEIN Projekt.
#
# Idempotent: kopiert die drei Arbeitsdateien aus den *.example-Vorlagen (ohne
# Bestehendes zu überschreiben), macht Skripte ausführbar, legt das State-/Audit-
# Verzeichnis an und führt einen Smoke-Check der Voraussetzungen durch.
#
#   bash bin/install.sh            # aus dem Skill-Ordner
#
# Danach: config.yml, .sds-env (Secrets!) und guardrails.deny anpassen.
set -euo pipefail
SDS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SDS"

say() { printf '  %s\n' "$*"; }

echo "→ Selfdeveloping System: Setup in $SDS"

# 1) Arbeitsdateien aus Vorlagen (nie überschreiben)
copy_if_absent() {
  if [ -e "$2" ]; then say "✓ $2 existiert bereits — unangetastet";
  else cp "$1" "$2"; say "＋ $2 aus $1 erstellt"; fi
}
copy_if_absent config.example.yml      config.yml
copy_if_absent guardrails.deny.example guardrails.deny
if [ -e .sds-env ]; then say "✓ .sds-env existiert bereits — unangetastet";
else cp .sds-env.example .sds-env; chmod 600 .sds-env; say "＋ .sds-env erstellt (chmod 600 — NIE committen)"; fi

# 2) Skripte ausführbar
chmod +x adapters/*.sh bin/*.sh
say "✓ adapters/*.sh & bin/*.sh ausführbar"

# 3) State-/Audit-Verzeichnis (Council-Urteile, Idempotenz-Log)
mkdir -p .sds-state/council
say "✓ .sds-state/ angelegt (Idempotenz-Log + Council-Audit)"

# 4) Voraussetzungen prüfen
echo "→ Voraussetzungen:"
ok=1
for c in bash python3 git gh; do
  if command -v "$c" >/dev/null 2>&1; then say "✓ $c"; else say "✗ $c FEHLT"; ok=0; fi
done
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && say "✓ gh ist eingeloggt" || { say "✗ gh nicht eingeloggt (gh auth login)"; ok=0; }
fi

echo
echo "Fertig. Nächste Schritte:"
echo "  1) .sds-env ausfüllen (API-Key / Tracker-IDs / States) — chmod 600 prüfen"
echo "  2) config.yml anpassen (tracker, repo.base_branch, verify.commands, deploy.enabled, council.*)"
echo "  3) guardrails.deny auf DEIN Projekt schärfen (Schema, Auth, Deploy, …)"
echo "  4) Smoke-Test:  bash $SDS/<tracker-adapter> poll"
echo "  5) Betrieb:     /loop 6h /selfdeveloping-system   (oder /schedule)"
[ "$ok" = 1 ] || { echo; echo "⚠ Es fehlen Voraussetzungen (siehe ✗ oben)."; exit 1; }
