#!/bin/bash
# Emits one JSON object describing Hermes agent status:
#   { "active": {...}|null, "sessions": [ ... ], "profiles": [...], "selectedProfile": "..." }
# Sessions come from local Hermes SQLite stores (per-profile).
# Only stdout JSON matters; everything else goes to stderr.

# Optional $1 = single-profile filter (load-on-select). Sanitized: hostname-safe chars only.
PROFILE_FILTER="${1:-}"
if [[ -n "$PROFILE_FILTER" ]]; then
  PROFILE_FILTER="$(printf %s "$PROFILE_FILTER" | tr -cd 'a-zA-Z0-9._-' | head -c 64)"
fi

# NOTE: this script reads no state files on purpose. The QML layer persists the
# selected profile via omarchy-shell settings and passes it as $1.

# --- Local profiles: ~/.hermes/profiles/*/state.db + ~/.hermes/state.db ---
LOCAL_PROFILES=[]
if [[ -d "$HOME/.hermes/profiles" ]]; then
  for d in "$HOME/.hermes/profiles"/*; do
    [[ -d "$d" ]] && LOCAL_PROFILES+=("$(basename "$d")")
  done
fi
LOCAL_PROFILES+=("default")

# Build local rows via python scanning all DBs (one process)
LOCAL_JSON=$(HERMES_PROFILE_FILTER="$PROFILE_FILTER" python3 -c '
import sqlite3, json, pathlib, os, sys
home=os.path.expanduser("~")
profiles=[]
p=pathlib.Path(home) / ".hermes" / "profiles"
if p.exists():
    for child in p.iterdir():
        if child.is_dir():
            profiles.append(child.name)
profiles.append("default")
full_profiles=sorted(set(profiles))
hf=os.environ.get("HERMES_PROFILE_FILTER") or ""
loop_profiles=([hf] if hf in full_profiles else []) if hf else full_profiles
profiles=full_profiles
all_rows=[]
for profile in loop_profiles:
    if profile=="default":
        db=str(pathlib.Path(home)/".hermes"/"state.db")
    else:
        db=str(pathlib.Path(home)/".hermes"/"profiles"/profile/"state.db")
    try:
        if not os.path.exists(db): continue
        if os.path.getsize(db)==0: continue
        con=sqlite3.connect(db)
        cur=con.cursor()
        cur.execute("""
            SELECT id,
                   substr(COALESCE(title,""),1,60)  AS title,
                   substr(COALESCE(cwd,""),1,120)   AS cwd,
                   substr(COALESCE(model,""),1,40)  AS model,
                   message_count AS messages,
                   last_activity_at AS last_active,
                   ended_at IS NULL OR last_activity_at > ended_at AS open,
                   COALESCE(profile_name, ?) AS profile
            FROM sessions
            WHERE hidden = 0 AND archived = 0
            ORDER BY last_activity_at DESC
            LIMIT 8;
        """, (profile,))
        cols=[d[0] for d in cur.description]
        for r in cur.fetchall():
            all_rows.append(dict(zip(cols,r)))
            # Tag by physical DB location
            all_rows[-1]["profile"] = profile
        con.close()
    except Exception as e:
        continue
all_rows=sorted(all_rows, key=lambda r: (r.get("last_active") or 0), reverse=True)[:32]
print(json.dumps({"profiles": profiles, "rows": all_rows}))
' 2>/dev/null | head -c 16384)

if [[ -n "$LOCAL_JSON" ]]; then
  echo "$LOCAL_JSON" | HERMES_PROFILE_FILTER="$PROFILE_FILTER" python3 -c '
import json, sys, time, os, pathlib
now=time.time()
LIVE_WINDOW=60
MAX_BYTES=16384
raw=sys.stdin.buffer.read(MAX_BYTES).decode("utf-8","replace").strip()
if not raw:
    print("{\"active\": null, \"sessions\": []}")
    sys.exit(0)
try: data=json.loads(raw)
except: data={"profiles":["default"],"rows":[]}
profiles=data.get("profiles") or ["default"]
rows=data.get("rows") or []
profiles=[str(p).strip() for p in profiles if str(p).strip()]
hf=os.environ.get("HERMES_PROFILE_FILTER") or ""
if hf:
    rows=[r for r in rows if str(r.get("profile") or "") == hf]
if not profiles: profiles=["default"]
selected=hf or None
if not selected:
    if "default" in profiles: selected="default"
    else: selected=profiles[0]
seen=set(); uniq=[]
for p in profiles:
    if p not in seen:
        seen.add(p); uniq.append(p)
profiles=uniq
def plain(t): return str(t or "").replace("<","‹").replace(">","›").replace("&","+")
sessions=[]
for r in rows[:32]:
    sessions.append({"id":str(r.get("id")or""),"title":plain(r.get("title"))or"(untitled)","cwd":plain(r.get("cwd")),"model":plain(r.get("model")),"messages":int(r.get("messages")or 0),"lastActiveTs":float(r.get("last_active")or 0),"live":bool(r.get("open")) and now - float(r.get("last_active")or 0) < LIVE_WINDOW,"profile":str(r.get("profile")or selected or "default")})
active=next((s for s in sessions if s["live"]),None)
if active is None and sessions and now - sessions[0]["lastActiveTs"] < 900: active=sessions[0]
print(json.dumps({"active":active,"sessions":sessions,"profiles":profiles,"selectedProfile":selected}))
'
  exit 0
fi

# Fallback empty (should be compatible with old QML)
printf "{\"active\": null, \"sessions\": [], \"profiles\": [\"default\"], \"selectedProfile\": \"default\"}\n"
