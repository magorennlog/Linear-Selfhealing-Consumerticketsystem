Behebt {{TICKET_ID}} ({{REQUEST_TYPE}}).

**Diagnose / Anforderung:** {{DIAGNOSIS}}

**Änderung:** {{CHANGE_SUMMARY}}

**Verifikation:** {{VERIFY_RESULT}} · {{FILES_CHANGED}} Datei(en), Guardrail-Check: PASS.

**Council:** Klassifikation {{CLASSIFY_CONFIDENCE}}% · Fix-Verifikation {{VERIFY_CONFIDENCE}}% (Schwelle {{THRESHOLD}}%).

Tracker: {{TICKET_URL}}

---
{{BOT_MARKER}} Automatisch erstellt vom **Selfdeveloping-System**-Skill.
Über der Confidence-Schwelle wird dieser PR autonom gemergt + deployt; sonst
liegt er hier zur **manuellen Freigabe** (Merge = Freigabe). Das deterministische
Pfad-Gate hat in beiden Fällen das letzte Wort.
