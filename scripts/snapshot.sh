#!/bin/bash
# Emits one JSON object describing Hermes agent status:
#   { "active": {...}|null, "sessions": [ ... ], "profiles": [...], "selectedProfile": "..." }
# Sessions come from Hermes SQLite stores (per-profile) via remote Docker or local fallback.
# Only stdout JSON matters; everything else goes to stderr.
#
# Bounded by design: query caps rows (8 per DB) and text lengths, python aggregates
# and sorts, head -c 8192 limits ssh payload, MAX_BYTES caps local json.

# --- BEGIN remote Hermes support (SSH via HERMES_REMOTE_HOST) ---
_HERMES_ENV_SET=0; [[ -n "${HERMES_REMOTE_HOST+set}" ]] && _HERMES_ENV_SET=1 && _HERMES_ENV_VAL="$HERMES_REMOTE_HOST"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $_HERMES_ENV_SET -eq 0 ]]; then
  if [[ -f "$SCRIPT_DIR/../remote.conf" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../remote.conf"
  fi
  if [[ -f "$HOME/.config/omarchy/plugins/kelso.hermes-sessions-config/remote.conf" ]]; then
    source "$HOME/.config/omarchy/plugins/kelso.hermes-sessions-config/remote.conf"
  fi
else
  HERMES_REMOTE_HOST="$_HERMES_ENV_VAL"
fi
REMOTE_HOST="${HERMES_REMOTE_HOST-}"

# Optional $1 = single-profile filter (load-on-select). Sanitized: the value is
# interpolated into an ssh command string, so only hostname-safe chars survive.
PROFILE_FILTER="${1:-}"
if [[ -n "$PROFILE_FILTER" ]]; then
  PROFILE_FILTER="$(printf %s "$PROFILE_FILTER" | tr -cd 'a-zA-Z0-9._-' | head -c 64)"
fi

# NOTE: this script reads no state files on purpose. The QML layer persists the
# selected profile via omarchy-shell settings and passes it as $1 (HF filter).
# Writing/reading files inside the plugin directory would trip the
# omarchy-shell hot-reload watcher and close open panels.

if [[ -n "$REMOTE_HOST" ]] && ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE_HOST" "exit" 2>/dev/null; then
  REMOTE_JSON=$(cat <<'PYEOF' | ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE_HOST" "docker exec -i -e HF=\"$PROFILE_FILTER\" hermes python3" 2>/dev/null | head -c 16384
import sqlite3, json, pathlib, os, sys
# Discover profiles: dirs under /opt/data/profiles + default, sorted unique
profiles = []
try:
    p = pathlib.Path("/opt/data/profiles")
    if p.exists():
        for child in p.iterdir():
            if child.is_dir():
                profiles.append(child.name)
except Exception:
    pass
if "default" not in profiles:
    profiles.append("default")
# de-duplicate and sort for stable UI; keep default first if present then alphabetically
full_profiles = sorted(set(profiles))
# Optional single-profile filter (HF env injected by snapshot.sh): read ONLY
# that profile's DB so the loop never touches the others, but keep full list
# for the tab bar (visible: profiles.length > 1).
hf = os.environ.get("HF") or ""
loop_profiles = ([hf] if hf in full_profiles else []) if hf else full_profiles
profiles = full_profiles
# Sort alphabetically for stable UI; QML picks selectedProfile
# Gather rows from each profile DB in ONE process
all_rows = []
for profile in loop_profiles:
    if profile == "default":
        db_path = "/opt/data/state.db"
    else:
        db_path = f"/opt/data/profiles/{profile}/state.db"
    try:
        if not os.path.exists(db_path):
            continue
        if os.path.getsize(db_path) == 0:
            continue
        con = sqlite3.connect(db_path)
        cur = con.cursor()
        # profile_name may be NULL for old sessions -> coalesce to profile folder name
        cur.execute("""
            SELECT id,
                   substr(COALESCE(title,''),1,60)  AS title,
                   substr(COALESCE(cwd,''),1,120)   AS cwd,
                   substr(COALESCE(model,''),1,40)  AS model,
                   message_count AS messages,
                   last_activity_at AS last_active,
                   ended_at IS NULL OR last_activity_at > ended_at AS open,
                   COALESCE(profile_name, ?) AS profile
            FROM sessions
            WHERE hidden = 0 AND archived = 0
            ORDER BY last_activity_at DESC
            LIMIT 8;
        """, (profile,))
        cols = [d[0] for d in cur.description]
        for r in cur.fetchall():
            all_rows.append(dict(zip(cols, r)))
            # Tag by the DB the row physically lives in (loop var), not by the
            # profile_name column — resume only resolves against the store of
            # the profile being opened, so the label must match the location.
            all_rows[-1]["profile"] = profile
        con.close()
    except Exception as e:
        # skip broken DBs (e.g. /opt/data/profiles/default/state.db with no table)
        try:
            sys.stderr.write(f"skip {db_path}: {e}\n")
        except:
            pass
        continue
# Sort aggregated by last_active DESC, keep up to 32 (8 per profile) for per-profile filtering in QML
all_rows = sorted(all_rows, key=lambda r: (r.get("last_active") or 0), reverse=True)[:32]
print(json.dumps({"profiles": profiles, "rows": all_rows}))
PYEOF
)
  if [[ -n "$REMOTE_JSON" ]]; then
    echo "$REMOTE_JSON" | HERMES_PROFILE_FILTER="$PROFILE_FILTER" python3 -c '
import json, sys, time, os, pathlib
now=time.time()
LIVE_WINDOW=60
MAX_BYTES=16384
raw=sys.stdin.buffer.read(MAX_BYTES).decode("utf-8","replace").strip()
if not raw:
    print("{\"active\": null, \"sessions\": [], \"profiles\": [\"default\"], \"selectedProfile\": \"default\"}")
    sys.exit(0)
try:
    data=json.loads(raw)
except Exception as e:
    print("{\"active\": null, \"sessions\": [], \"profiles\": [\"default\"], \"selectedProfile\": \"default\"}")
    sys.exit(0)
profiles=data.get("profiles") or ["default"]
rows=data.get("rows") or []
# sanitize profiles
profiles=[str(p).strip() for p in profiles if str(p).strip()]
hf=os.environ.get("HERMES_PROFILE_FILTER") or ""
if hf:
    # Filter only rows; keep full profiles list so tab bar stays visible (visible: profiles.length > 1)
    rows=[r for r in rows if str(r.get("profile") or "") == hf]
if not profiles:
    profiles=["default"]
# resolve selectedProfile: explicit filter first, else "default", else first.
# The QML layer persists the chosen profile via settings and passes it as $1;
# this script deliberately reads no state files (a file inside the plugin dir
# would trip omarchy-shell hot-reload watcher).
selected=hf or None
if not selected:
    if "default" in profiles:
        selected="default"
    else:
        selected=profiles[0]
# de-duplicate profiles preserve sorted order
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
fi
# --- END remote ---

# --- Local fallback (when SSH unreachable) ---
# Discover local profiles: ~/.hermes/profiles/*/state.db + ~/.hermes/state.db
LOCAL_PROFILES=[]
if [[ -d "$HOME/.hermes/profiles" ]]; then
  for d in "$HOME/.hermes/profiles"/*; do
    [[ -d "$d" ]] && LOCAL_PROFILES+=("$(basename "$d")")
  done
fi
LOCAL_PROFILES+=("default")
# de-duplicate
LOCAL_PROFILES_U=$(printf "%s\n" "${LOCAL_PROFILES[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
# Build local rows via python scanning all DBs (one process, no ssh)
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
            # Tag by physical DB location (see remote loop note above)
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
