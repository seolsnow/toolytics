#!/usr/bin/env bash
# Claude Code toolytics tracker.
# Scans ~/.claude/projects/**/*.jsonl, accumulates tidy tables
#   tools:   (date, triggered_by, project, tool, count)
#   tokens:  (date, triggered_by, project, model, input, output, cache_read, cw5m, cw1h)
#   injects: (date, triggered_by, project, source, count)
# into persistent history DBs, rebuilds a self-contained dashboard, and opens it.
#
# Usage:  ./build.sh [VIEW_DAYS]      # default dashboard window, default 30 (data keeps ALL)
#         ./build.sh --selfcheck      # run merge/dedup invariant checks and exit
# Env:    TOOLYTICS_HOME  output dir (default ~/.toolytics)
#         TOOLYTICS_OPEN  set 0 to skip opening the browser
#         TOOLYTICS_TRIM  comma-separated leading path segments to drop from project
#                        labels, e.g. "hsc,work" (default empty — labels are home-relative)
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"          # holds dashboard.template.html
OUT="${TOOLYTICS_HOME:-$HOME/.toolytics}"        # persistent base (history + dashboard)

if [ "${1:-}" = "--selfcheck" ]; then
  python3 - <<'PY'
# ponytail: the only non-trivial logic here is replace-by-date merge + the
# inject reverse-map. One runnable check each; fails loudly if either regresses.
import datetime
def merge_by_date(existing, scanned_dates, new_rows, keylen):
    # mirror of the merge in the main script: drop existing rows whose date the
    # scan covered (scan is authoritative for those), keep the rest, add new.
    hist = {k: v for k, v in existing.items() if k[0] not in scanned_dates}
    hist.update(new_rows)
    return hist

# 1. idempotent: re-merging the same scan twice == once (re-run doesn't inflate)
old = {('2026-01-01','main','p','Bash'): 5, ('2026-01-02','main','p','Read'): 9}
scan = {('2026-01-02','main','p','Read'): 9, ('2026-01-02','main','p','Edit'): 2}
sd = {'2026-01-02'}
once = merge_by_date(old, sd, scan, 4)
twice = merge_by_date(once, sd, scan, 4)
assert once == twice, "merge not idempotent"
# 2. rotated-out date preserved (2026-01-01 not in scan -> kept)
assert once[('2026-01-01','main','p','Bash')] == 5, "rotated date wiped"
# 3. covered date replaced wholesale (old Read=9 stays via scan, no stale leftovers)
assert ('2026-01-02','main','p','Edit') in once and once[('2026-01-02','main','p','Read')] == 9
# 4. a date the scan covered but produced nothing for is fully cleared
old2 = {('2026-02-01','main','p','Bash'): 7}
assert merge_by_date(old2, {'2026-02-01'}, {}, 4) == {}, "covered-empty date not cleared"

# 5. inject reverse-map: exact-match on command string AND on statusMessage
def resolve(cmd, m):
    return m.get(cmd.strip(), '?')
m = {'"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start': 'superpowers',
     'Loading Karpathy guidelines...': 'karpathy'}
assert resolve('"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start', m) == 'superpowers'
assert resolve('Loading Karpathy guidelines...', m) == 'karpathy'   # statusMessage path
assert resolve('bash /some/unknown/thing.sh', m) == '?'             # unknown -> fallback
print("selfcheck OK: 5 assertions passed")
PY
  exit 0
fi

VIEW_DAYS="${1:-30}"
mkdir -p "$OUT"

python3 - "$VIEW_DAYS" "$SRC" "$OUT" <<'PY'
import sys, os, glob, json, csv, datetime, collections

view_days = int(sys.argv[1]); src, out = sys.argv[2], sys.argv[3]
HOME = os.path.expanduser('~')

# --- model pricing (USD per 1M tokens), as of 2026-06. Update here when Anthropic changes them. ---
# cache read = 0.1x input, cache write 5m = 1.25x input, 1h = 2x input.
PRICE = {  # canonical key (substring-matched against the logged model id)
  'fable-5': (10.0, 50.0), 'mythos-5': (10.0, 50.0),
  'opus-4-8': (5.0, 25.0), 'opus-4-7': (5.0, 25.0), 'opus-4-6': (5.0, 25.0), 'opus-4-5': (5.0, 25.0),
  'sonnet-4-6': (3.0, 15.0), 'sonnet-4-5': (3.0, 15.0),
  'haiku-4-5': (1.0, 5.0),
}
def canon_model(m):
    m = (m or '').lower()
    for key in PRICE:
        if key in m: return key
    return m or 'unknown'

# optional cosmetic shortening: TOOLYTICS_TRIM="hsc,work" strips a leading path
# segment from labels. Empty by default — no personal prefix baked into the distro.
TRIM = [p.strip().strip('/') for p in os.environ.get('TOOLYTICS_TRIM', '').split(',') if p.strip()]
def label_from_cwd(cwd):
    rel = cwd[len(HOME):].lstrip('/') if cwd.startswith(HOME) else cwd.lstrip('/')
    for pre in TRIM:                                    # strip first matching leading segment
        if rel == pre: rel = ''; break
        if rel.startswith(pre + '/'): rel = rel[len(pre) + 1:]; break
    return rel or 'home'
def label_from_dir(p):                                  # fallback if a file has no cwd
    return p.lstrip('-').replace('-', '/') or 'home'

def pts(s):
    try: return datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: return None

# --- inject reverse-map, built from what's installed on disk (portable per-machine) ---
# the transcript logs the hook's `command` UNEXPANDED (${CLAUDE_PLUGIN_ROOT} intact),
# or — when the hook sets a statusMessage — logs the statusMessage string instead.
# neither names the plugin, so we map: every SessionStart command/statusMessage string
# on disk -> a plugin label (from the plugin path, or from a plugins/ path inside a
# user-settings command, else a cleaned string). exact-match the logged command against it.
# => any plugin on any machine resolves with zero hardcoding; unknown ones still get a label.
def plugin_from_path(p):
    # cache/<marketplace>/<plugin>/<version>/...  — prefer the plugin segment, but a
    # globbed command path (cache/karpathy-skills/*/*/...) leaves '*' there, so fall back.
    if '/cache/' in p:
        seg = p.split('/cache/')[1].split('/')
        if len(seg) > 1 and seg[1] not in ('', '*'): return seg[1]
        return seg[0] or None
    if '/marketplaces/' in p:
        return p.split('/marketplaces/')[1].split('/')[0] or None
    return None
def plugin_in_cmd(cmd):                                 # user-settings cmd may reference a plugin path
    for marker in ('/cache/', '/marketplaces/'):
        if marker in cmd:
            return plugin_from_path(cmd)
    return None
def clean_label(s):
    s = s.strip().strip('"').strip()
    pl = plugin_in_cmd(s)
    if pl: return pl
    # statusMessage like "Loading Karpathy guidelines..." -> "karpathy"
    low = s.lower()
    if low.startswith('loading '):
        return low[len('loading '):].split()[0].strip('.') if low[len('loading '):].split() else s
    # command path -> basename of the script
    tok = s.replace('${CLAUDE_PLUGIN_ROOT}/hooks/', '').strip('" ').split('/')[-1].split()[0]
    return tok or s

def build_inject_map():
    m = {}
    for f in glob.glob(os.path.expanduser('~/.claude/plugins/**/hooks.json'), recursive=True):
        try: cfg = json.load(open(f))
        except Exception: continue
        plugin = plugin_from_path(f)
        for grp in (cfg.get('hooks', {}) or {}).get('SessionStart', []) or []:
            for h in grp.get('hooks', []) or []:
                cmd = (h.get('command') or '').strip()
                sm  = (h.get('statusMessage') or '').strip()
                if cmd: m.setdefault(cmd, plugin or clean_label(cmd))
                if sm:  m.setdefault(sm,  plugin or clean_label(sm))
    for sf in ('~/.claude/settings.json', '~/.claude/settings.local.json'):
        try: cfg = json.load(open(os.path.expanduser(sf)))
        except Exception: continue
        for grp in (cfg.get('hooks', {}) or {}).get('SessionStart', []) or []:
            for h in grp.get('hooks', []) or []:
                cmd = (h.get('command') or '').strip()
                sm  = (h.get('statusMessage') or '').strip()
                # statusMessage hooks log the statusMessage as `command`; map both.
                if sm:  m.setdefault(sm,  plugin_in_cmd(cmd) or clean_label(sm))
                if cmd: m.setdefault(cmd, plugin_in_cmd(cmd) or clean_label(cmd))
    return m
INJECT_MAP = build_inject_map()
def attrib_inject(a):
    if a.get('type') != 'hook_success' or a.get('hookEvent') != 'SessionStart':
        return None
    cmd = (a.get('command') or '').strip()
    if not cmd: return None
    return INJECT_MAP.get(cmd) or clean_label(cmd)      # exact match, else cleaned fallback

# --- 1. full scan of everything currently on disk (no time window) ---
# ponytail: full rescan each run (~2s now). If files balloon, switch to mtime-incremental.
files = glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True)
bydir = collections.defaultdict(list)
for f in files:
    bydir[f.split('/projects/')[1].split('/')[0]].append(f)

def first_cwd(fs):
    for f in fs:
        for line in open(f, errors='ignore'):
            try: o = json.loads(line)
            except Exception: continue
            if o.get('cwd'): return o['cwd']
    return None

labels = {}
for d, fs in bydir.items():
    mains = [f for f in fs if '/subagents/' not in f] or fs
    cwd = first_cwd(mains) or first_cwd(fs)
    labels[d] = label_from_cwd(cwd) if cwd else label_from_dir(d)

scan   = collections.Counter()   # (date, by, project, tool) -> count
tok    = collections.Counter()   # (date, by, project, model, field) -> tokens
inj    = collections.Counter()   # (date, by, project, source) -> firings
scanned_dates = set()            # every date present on disk -> scan is authoritative for it
for f in files:
    by   = 'agent' if '/subagents/' in f else 'main'
    proj = labels[f.split('/projects/')[1].split('/')[0]]
    for line in open(f, errors='ignore'):
        try: o = json.loads(line)
        except Exception: continue
        t = pts(o.get('timestamp', '') or '')
        if not t: continue
        d = t.date().isoformat()
        scanned_dates.add(d)                            # any timestamped record == date is on disk
        if o.get('type') == 'attachment':
            isrc = attrib_inject(o.get('attachment') or {})
            if isrc: inj[(d, by, proj, isrc)] += 1
            continue
        msg = o.get('message')
        if not isinstance(msg, dict): continue
        u = msg.get('usage')
        if isinstance(u, dict):
            cm = canon_model(msg.get('model'))
            cc = u.get('cache_creation') or {}
            tok[(d, by, proj, cm, 'input')]      += u.get('input_tokens', 0) or 0
            tok[(d, by, proj, cm, 'output')]     += u.get('output_tokens', 0) or 0
            tok[(d, by, proj, cm, 'cache_read')] += u.get('cache_read_input_tokens', 0) or 0
            tok[(d, by, proj, cm, 'cw5m')]       += cc.get('ephemeral_5m_input_tokens', 0) or 0
            tok[(d, by, proj, cm, 'cw1h')]       += cc.get('ephemeral_1h_input_tokens', 0) or 0
        c = msg.get('content')
        if not isinstance(c, list): continue
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'tool_use':
                n = b.get('name', '?')
                if n == 'Skill':
                    n = 'skill:' + str((b.get('input') or {}).get('skill', '?'))
                scan[(d, by, proj, n)] += 1

# --- 2. merge into history DBs by REPLACE-BY-DATE (idempotent; preserves rotated-out dates) ---
def load(path, ncols):
    h = {}
    if os.path.exists(path):
        with open(path) as fh:
            r = csv.reader(fh); next(r, None)
            for row in r:
                if len(row) == ncols:
                    *key, val = row
                    h[tuple(key)] = int(val)
    return h
def merge_write(path, header, existing, scan_counter):
    hist = {k: v for k, v in existing.items() if k[0] not in scanned_dates}
    hist.update(scan_counter)
    rows = sorted([list(k) + [v] for k, v in hist.items()])
    with open(path, 'w', newline='') as fh:
        w = csv.writer(fh); w.writerow(header); w.writerows(rows)
    return rows

tool_rows = merge_write(os.path.join(out, 'history.csv'),
    ['date', 'triggered_by', 'project', 'tool', 'count'],
    load(os.path.join(out, 'history.csv'), 5), scan)
inj_rows = merge_write(os.path.join(out, 'injects.csv'),
    ['date', 'triggered_by', 'project', 'source', 'count'],
    load(os.path.join(out, 'injects.csv'), 5), inj)

# tokens DB: 5 token fields collapse into one wide row per (date,by,proj,model)
tpath = os.path.join(out, 'tokens.csv')
THEAD = ['date', 'triggered_by', 'project', 'model', 'input', 'output', 'cache_read', 'cw5m', 'cw1h']
TFIELDS = ['input', 'output', 'cache_read', 'cw5m', 'cw1h']
tok_existing = {}
if os.path.exists(tpath):
    with open(tpath) as fh:
        r = csv.reader(fh); next(r, None)
        for row in r:
            if len(row) == 9:
                tok_existing[tuple(row[:4])] = [int(x) for x in row[4:]]
tok_wide = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
for (d, by, proj, model, field), v in tok.items():
    tok_wide[(d, by, proj, model)][TFIELDS.index(field)] += v
tok_hist = {k: v for k, v in tok_existing.items() if k[0] not in scanned_dates}
tok_hist.update(tok_wide)
tok_rows = sorted([list(k) + v for k, v in tok_hist.items()])
with open(tpath, 'w', newline='') as fh:
    w = csv.writer(fh); w.writerow(THEAD); w.writerows(tok_rows)

# --- skill inventory on disk (so never-invoked skills still show, count 0) ---
seen = set(); skill_inv = []   # [leaf, origin, label]
for f in sorted(glob.glob(os.path.expanduser('~/.claude/skills/*/SKILL.md'))):
    leaf = os.path.basename(os.path.dirname(f))
    if leaf not in seen:
        seen.add(leaf); skill_inv.append([leaf, 'user', leaf])
for f in sorted(glob.glob(os.path.expanduser('~/.claude/plugins/**/skills/*/SKILL.md'), recursive=True)):
    leaf = os.path.basename(os.path.dirname(f))
    if leaf in seen: continue
    pl = plugin_from_path(f)
    seen.add(leaf); skill_inv.append([leaf, 'plugin', (pl + ':' + leaf) if pl else leaf])

# --- 3. build dashboard from full history; default view = trailing VIEW_DAYS ---
all_dates = sorted({r[0] for r in tool_rows} | {r[0] for r in tok_rows})
today = datetime.date.today()
default_from = max(all_dates[0], (today - datetime.timedelta(days=view_days)).isoformat()) if all_dates else today.isoformat()
meta = {
    'rows': tool_rows,
    'tokens': tok_rows,
    'price': PRICE,
    'skill_inv': skill_inv,
    'injects': inj_rows,
    'default_from': default_from,
    'view_days': view_days,
    'generated': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
    'total': sum(r[4] for r in tool_rows),
}
data_js = 'const DATA=' + json.dumps(meta, ensure_ascii=False, separators=(',', ':')) + ';'
tpl = open(os.path.join(src, 'dashboard.template.html')).read()
open(os.path.join(out, 'dashboard.html'), 'w').write(tpl.replace('/*__DATA__*/', data_js))

# cost estimate over full history (display-only echo)
def cost_of(model, inp, out_, cr, c5, c1):
    p = PRICE.get(model)
    if not p: return 0.0
    pin, pout = p
    return (inp*pin + out_*pout + cr*0.1*pin + c5*1.25*pin + c1*2*pin) / 1e6
total_cost = sum(cost_of(r[3], *r[4:]) for r in tok_rows)
span = f'{all_dates[0]}..{all_dates[-1]}' if all_dates else '(empty)'
print(f'history.csv: {len(tool_rows)} rows, {meta["total"]} calls')
print(f'tokens.csv:  {len(tok_rows)} rows, ~${total_cost:,.0f} est. API value')
print(f'injects.csv: {len(inj_rows)} rows; inject sources: {sorted({r[3] for r in inj_rows})}')
print(f'dashboard.html: {os.path.getsize(os.path.join(out,"dashboard.html"))//1024} KB  span {span}  (default view: last {view_days}d)')
PY

DASH="$OUT/dashboard.html"
echo "→ $DASH"
if [ "${TOOLYTICS_OPEN:-1}" != "0" ]; then
  open "$DASH" 2>/dev/null || xdg-open "$DASH" 2>/dev/null || true
fi
