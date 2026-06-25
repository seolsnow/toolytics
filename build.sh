#!/usr/bin/env bash
# Claude Code + Codex toolytics tracker.
# Scans ~/.claude/projects/**/*.jsonl and ~/.codex/sessions/**/*.jsonl, accumulates tidy tables
#   tools:   (date, runtime, triggered_by, project, tool, count)
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
  python3 - "$SRC/build.sh" <<'PY'
# ponytail: the only non-trivial logic here is replace-by-date merge + the
# inject reverse-map. One runnable check each; fails loudly if either regresses.
import datetime, os, json, csv, tempfile, subprocess, sys
def merge_by_group(existing, scanned_groups, new_rows):
    # mirror of the merge in the main script: drop existing rows whose (date,by,project)
    # GROUP the scan covered (scan is authoritative for those), keep the rest, add new.
    hist = {k: v for k, v in existing.items() if (k[0], k[1], k[2]) not in scanned_groups}
    hist.update(new_rows)
    return hist

# 1. idempotent: re-merging the same scan twice == once (re-run doesn't inflate)
old = {('2026-01-01','main','p','Bash'): 5, ('2026-01-02','main','p','Read'): 9}
scan = {('2026-01-02','main','p','Read'): 9, ('2026-01-02','main','p','Edit'): 2}
g = {('2026-01-02','main','p')}
once = merge_by_group(old, g, scan)
assert once == merge_by_group(once, g, scan), "merge not idempotent"
# 2. rotated-out group preserved (2026-01-01 group not in scan -> kept)
assert once[('2026-01-01','main','p','Bash')] == 5, "rotated group wiped"
# 3. covered group replaced wholesale (scan value wins, no stale leftovers)
assert ('2026-01-02','main','p','Edit') in once and once[('2026-01-02','main','p','Read')] == 9
# 4. a group the scan covered but produced nothing for is fully cleared
assert merge_by_group({('2026-02-01','main','p','Bash'): 7}, {('2026-02-01','main','p')}, {}) == {}, "covered-empty group not cleared"
# 5. partial deletion: SAME date, project B's logs gone but A still on disk -> B's rows preserved
mixed = {('2026-03-01','main','A','Read'): 4, ('2026-03-01','main','B','Read'): 8}
kept = merge_by_group(mixed, {('2026-03-01','main','A')}, {('2026-03-01','main','A','Read'): 4})
assert kept[('2026-03-01','main','B','Read')] == 8, "partial-date deletion wiped an untouched project"

# 5. inject reverse-map: exact-match on command string AND on statusMessage
def resolve(cmd, m):
    return m.get(cmd.strip(), '?')
m = {'"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start': 'superpowers',
     'Loading Karpathy guidelines...': 'karpathy'}
assert resolve('"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start', m) == 'superpowers'
assert resolve('Loading Karpathy guidelines...', m) == 'karpathy'   # statusMessage path
assert resolve('bash /some/unknown/thing.sh', m) == '?'             # unknown -> fallback

# 6. learned cache (no-regress) + opt-in alias — mirror of attrib_inject's resolution.
def attrib(cmd, disk_resolved, disk_fallback, learned, alias):
    hi = disk_resolved.get(cmd)
    raw = hi or learned.get(cmd) or disk_fallback.get(cmd) or cmd.split('/')[-1]
    lab = alias.get(raw, raw)
    if hi or lab != raw: learned[cmd] = lab
    return lab
L = {}
assert attrib('cmdA', {'cmdA': 'superpowers'}, {}, L, {}) == 'superpowers'  # disk resolves -> learn
assert L.get('cmdA') == 'superpowers'
assert attrib('cmdA', {}, {}, L, {}) == 'superpowers', "learned cache regressed to basename after disk skew"
La = {}                                                                     # orphan predating cache:
assert attrib('x/check-setup.sh', {}, {}, La, {'check-setup.sh': 'superpowers'}) == 'superpowers'
assert La.get('x/check-setup.sh') == 'superpowers', "alias did not seed the cache"

# 7. Codex scan: main/subagent calls are collected separately and a legacy Claude
# history row survives the schema migration.
script = sys.argv[1]
with tempfile.TemporaryDirectory() as home:
    root = os.path.join(home, '.codex', 'sessions', '2026', '06', '25')
    os.makedirs(root)
    main_rows = [
        {'timestamp': '2026-06-25T01:00:00Z', 'type': 'session_meta',
         'payload': {'cwd': home, 'thread_source': 'user', 'source': 'cli'}},
        {'timestamp': '2026-06-25T01:00:01Z', 'type': 'response_item',
         'payload': {'type': 'function_call', 'name': 'exec_command'}},
    ]
    agent_rows = [
        {'timestamp': '2026-06-25T01:00:02Z', 'type': 'session_meta',
         'payload': {'cwd': home, 'source': {'subagent': {}}}},
        {'timestamp': '2026-06-25T01:00:03Z', 'type': 'response_item',
         'payload': {'type': 'custom_tool_call', 'name': 'exec'}},
    ]
    thread_agent_rows = [
        {'timestamp': '2026-06-25T01:00:04Z', 'type': 'session_meta',
         'payload': {'cwd': home, 'thread_source': 'subagent', 'source': 'cli'}},
        {'timestamp': '2026-06-25T01:00:05Z', 'type': 'response_item',
         'payload': {'type': 'function_call', 'name': 'view_image'}},
    ]
    for name, rows in [('main.jsonl', main_rows), ('agent.jsonl', agent_rows),
                       ('thread-agent.jsonl', thread_agent_rows)]:
        with open(os.path.join(root, name), 'w') as fh:
            fh.writelines(json.dumps(row) + '\n' for row in rows)
    # Claude transcript: a user-typed /slash skill-command arrives as STRING
    # content with no Skill tool_use -> counted as skill:<name> iff it maps to a
    # disk skill; a builtin like /clear must be ignored (no row). A GLOBAL skill
    # (~/.claude/skills) is tagged project=None; a PROJECT-LOCAL skill
    # (<cwd>/.claude/skills) is tagged with its owning project even when never used.
    pcwd = os.path.join(home, 'proj-a')
    os.makedirs(os.path.join(home, '.claude', 'skills', 'mytool'))
    open(os.path.join(home, '.claude', 'skills', 'mytool', 'SKILL.md'), 'w').close()
    os.makedirs(os.path.join(pcwd, '.claude', 'skills', 'projskill'))
    open(os.path.join(pcwd, '.claude', 'skills', 'projskill', 'SKILL.md'), 'w').close()
    proj = os.path.join(home, '.claude', 'projects', '-proj')
    os.makedirs(proj)
    with open(os.path.join(proj, 'sess.jsonl'), 'w') as fh:
        for cmd in ('/mytool', '/clear'):
            fh.write(json.dumps({'timestamp': '2026-06-25T02:00:00Z', 'type': 'user',
                'cwd': pcwd, 'message': {'role': 'user',
                'content': '<command-name>%s</command-name>\n<command-args></command-args>' % cmd}}) + '\n')
    out = os.path.join(home, 'out')
    os.makedirs(out)
    with open(os.path.join(out, 'history.csv'), 'w') as fh:
        fh.write('date,triggered_by,project,tool,count\n2026-06-25,main,legacy,Read,7\n')
    subprocess.run([script, '1'], check=True, env={**os.environ, 'HOME': home,
                   'TOOLYTICS_HOME': out, 'TOOLYTICS_OPEN': '0'})
    with open(os.path.join(out, 'history.csv')) as fh:
        got = list(csv.DictReader(fh))
    assert {(r['runtime'], r['triggered_by'], r['tool']) for r in got} == {
        ('claude', 'main', 'Read'), ('codex', 'main', 'exec_command'),
        ('codex', 'agent', 'exec'), ('codex', 'agent', 'view_image'),
        ('claude', 'main', 'skill:mytool')}   # /mytool counted, /clear ignored
    dashboard = open(os.path.join(out, 'dashboard.html')).read()
    # project-scoped skill visibility: a never-used project-local skill enters the
    # roster tagged with its project; the global skill stays project=None; and the
    # universe is project-filtered client-side (not just the counts).
    assert '["projskill","user","projskill","proj-a"]' in dashboard, "project-local skill not tagged with its project"
    assert '["mytool","user","mytool",null]' in dashboard, "global skill should be project=None"
    assert 'inf.project==null||S.projs.has(inf.project)' in dashboard, "skill universe is not project-filtered"
    assert 'id="f-runtime"' in dashboard, "dashboard has no runtime filter"
    assert 'function passTool(r)' in dashboard, "dashboard does not filter six-field tool rows"

# 8. plugin manifests agree on version (bump-version.sh keeps them in sync).
repo = os.path.dirname(os.path.abspath(sys.argv[1]))
vers = {}
for rel, path in [('.claude-plugin/plugin.json', ('version',)),
                  ('.claude-plugin/marketplace.json', ('metadata', 'version')),
                  ('.codex-plugin/plugin.json', ('version',))]:
    obj = json.load(open(os.path.join(repo, rel)))
    for k in path: obj = obj[k]
    vers[rel] = obj
assert len(set(vers.values())) == 1, f"plugin manifest versions disagree: {vers}"
print("selfcheck OK: all assertions passed")
PY
  exit 0
fi

VIEW_DAYS="${1:-30}"
mkdir -p "$OUT"

python3 - "$VIEW_DAYS" "$SRC" "$OUT" <<'PY'
import sys, os, glob, json, csv, datetime, collections, re

view_days = int(sys.argv[1]); src, out = sys.argv[2], sys.argv[3]
HOME = os.path.expanduser('~')

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
    # split high-confidence (plugin name derived from a path) from low-confidence
    # (cleaned basename / statusMessage). only the former is worth persisting, so a
    # later version skew can't downgrade a once-resolved label to a bare basename.
    resolved, fallback = {}, {}
    def add(key, plugin):
        if not key: return
        if plugin: resolved.setdefault(key, plugin)
        else: fallback.setdefault(key, clean_label(key))
    for f in glob.glob(os.path.expanduser('~/.claude/plugins/**/hooks.json'), recursive=True):
        try: cfg = json.load(open(f))
        except Exception: continue
        plugin = plugin_from_path(f)
        for grp in (cfg.get('hooks', {}) or {}).get('SessionStart', []) or []:
            for h in grp.get('hooks', []) or []:
                add((h.get('command') or '').strip(), plugin)
                add((h.get('statusMessage') or '').strip(), plugin)
    for sf in ('~/.claude/settings.json', '~/.claude/settings.local.json'):
        try: cfg = json.load(open(os.path.expanduser(sf)))
        except Exception: continue
        for grp in (cfg.get('hooks', {}) or {}).get('SessionStart', []) or []:
            for h in grp.get('hooks', []) or []:
                cmd = (h.get('command') or '').strip()
                pl = plugin_in_cmd(cmd)                          # user-settings cmd may name a plugin path
                add((h.get('statusMessage') or '').strip(), pl)  # statusMessage is logged as `command`
                add(cmd, pl)
    return resolved, fallback
DISK_RESOLVED, DISK_FALLBACK = build_inject_map()

# learned attribution cache (per machine, persistent at out/inject-map.json): a
# command string -> label, remembered while it was resolvable. when a plugin later
# renames or deletes its SessionStart hook script, current disk can no longer name
# it — the cache still can. this is the GENERAL fix for version skew (works for any
# plugin, not a per-plugin alias); monotonic — current disk always wins and refreshes.
LEARN_PATH = os.path.join(out, 'inject-map.json')
try: LEARNED = json.load(open(LEARN_PATH))
except Exception: LEARNED = {}
LEARNED.update(DISK_RESOLVED)

# opt-in relabel for orphans that predate the cache (a hook deleted before toolytics
# ever scanned it — e.g. an old superpowers check-setup.sh). portable: empty by
# default, the user supplies it. TOOLYTICS_INJECT_ALIAS="check-setup.sh=superpowers,foo=bar"
ALIAS = {}
for pair in (os.environ.get('TOOLYTICS_INJECT_ALIAS') or '').split(','):
    if '=' in pair:
        k, v = pair.split('=', 1); ALIAS[k.strip()] = v.strip()

def attrib_inject(a):
    if a.get('type') != 'hook_success' or a.get('hookEvent') != 'SessionStart':
        return None
    cmd = (a.get('command') or '').strip()
    if not cmd: return None
    hi  = DISK_RESOLVED.get(cmd)                                          # high-confidence (on disk now)
    raw = hi or LEARNED.get(cmd) or DISK_FALLBACK.get(cmd) or clean_label(cmd)
    lab = ALIAS.get(raw, raw)
    if hi or lab != raw:            # disk-resolved or user-aliased -> remember (also seeds from alias)
        LEARNED[cmd] = lab
    return lab

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

labels = {}; proj_cwds = {}        # label -> a real cwd, for project-local skill scan
for d, fs in bydir.items():
    mains = [f for f in fs if '/subagents/' not in f] or fs
    cwd = first_cwd(mains) or first_cwd(fs)
    labels[d] = label_from_cwd(cwd) if cwd else label_from_dir(d)
    if cwd: proj_cwds.setdefault(labels[d], cwd)

# --- skill inventory on disk (so never-invoked skills still show, count 0).
#     Built before the scan so user-typed /slash skill-commands can be matched. ---
seen = set(); skill_inv = []   # [leaf, origin, label, project]  (project=None => global)
for f in sorted(glob.glob(os.path.expanduser('~/.claude/skills/*/SKILL.md'))):
    leaf = os.path.basename(os.path.dirname(f))
    if leaf not in seen:
        seen.add(leaf); skill_inv.append([leaf, 'user', leaf, None])
for f in sorted(glob.glob(os.path.expanduser('~/.claude/plugins/**/skills/*/SKILL.md'), recursive=True)):
    leaf = os.path.basename(os.path.dirname(f))
    if leaf in seen: continue
    pl = plugin_from_path(f)
    seen.add(leaf); skill_inv.append([leaf, 'plugin', (pl + ':' + leaf) if pl else leaf, None])
# project-local skills (<cwd>/.claude/skills) tagged with their owning project, so the
# dashboard shows them (count 0) even if never invoked AND hides them under a different
# project filter. Global skills above are project=None (shown everywhere). Same-leaf as a
# global skill -> global wins (leaf-collision, deferred).
for label, cwd in proj_cwds.items():
    for f in sorted(glob.glob(os.path.join(cwd, '.claude', 'skills', '*', 'SKILL.md'))):
        leaf = os.path.basename(os.path.dirname(f))
        if leaf in seen: continue
        seen.add(leaf); skill_inv.append([leaf, 'user', leaf, label])
skill_leaves = {r[0] for r in skill_inv}   # leaf set for /slash skill-command matching

scan   = collections.Counter()   # (date, runtime, by, project, tool) -> count
inj    = collections.Counter()   # (date, by, project, source) -> firings
tool_scanned_groups = set()      # (date,runtime,by,project) groups present on disk -> scan is authoritative
claude_scanned_groups = set()    # (date,by,project), for the Claude-only inject table
                                 # Both are finer than whole-date: a date with project A still on disk but
                                 # project B's logs deleted won't wipe B's accumulated rows.
for f in files:
    by   = 'agent' if '/subagents/' in f else 'main'
    proj = labels[f.split('/projects/')[1].split('/')[0]]
    for line in open(f, errors='ignore'):
        try: o = json.loads(line)
        except Exception: continue
        t = pts(o.get('timestamp', '') or '')
        if not t: continue
        d = t.date().isoformat()
        tool_scanned_groups.add((d, 'claude', by, proj))
        claude_scanned_groups.add((d, by, proj))
        if o.get('type') == 'attachment':
            isrc = attrib_inject(o.get('attachment') or {})
            if isrc: inj[(d, by, proj, isrc)] += 1
            continue
        msg = o.get('message')
        if not isinstance(msg, dict): continue
        c = msg.get('content')
        if isinstance(c, str):
            # user-typed /slash skill-command: no Skill tool_use is emitted, so
            # this command-name is its only trace. Count only commands that map to
            # a known skill (builtins like /clear,/model are ignored); reuse the
            # skill:<name> label of the model path so the two paths merge.
            m = re.search(r'<command-name>/?([^<\s]+)</command-name>', c)
            if m and m.group(1).split(':')[-1] in skill_leaves:
                scan[(d, 'claude', by, proj, 'skill:' + m.group(1))] += 1
            continue
        if not isinstance(c, list): continue
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'tool_use':
                n = b.get('name', '?')
                if n == 'Skill':
                    n = 'skill:' + str((b.get('input') or {}).get('skill', '?'))
                scan[(d, 'claude', by, proj, n)] += 1

def codex_context(path):
    by, cwd = 'main', None
    for line in open(path, errors='ignore'):
        try: record = json.loads(line)
        except Exception: continue
        payload = record.get('payload')
        if not isinstance(payload, dict): continue
        if record.get('type') == 'session_meta':
            cwd = cwd or payload.get('cwd')
            source = payload.get('source')
            if payload.get('thread_source') == 'subagent' or (
                isinstance(source, dict) and 'subagent' in source):
                by = 'agent'
        elif record.get('type') == 'turn_context':
            cwd = cwd or payload.get('cwd')
    return by, label_from_cwd(cwd) if cwd else 'codex'

for f in glob.glob(os.path.expanduser('~/.codex/sessions/**/*.jsonl'), recursive=True):
    by, proj = codex_context(f)
    for line in open(f, errors='ignore'):
        try: record = json.loads(line)
        except Exception: continue
        t = pts(record.get('timestamp', '') or '')
        if not t: continue
        d = t.date().isoformat()
        tool_scanned_groups.add((d, 'codex', by, proj))
        payload = record.get('payload')
        if not isinstance(payload, dict) or record.get('type') != 'response_item': continue
        if payload.get('type') not in ('function_call', 'custom_tool_call'): continue
        name = payload.get('name')
        if name: scan[(d, 'codex', by, proj, name)] += 1

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
    hist = {k: v for k, v in existing.items() if (k[0], k[1], k[2]) not in claude_scanned_groups}
    hist.update(scan_counter)
    rows = sorted([list(k) + [v] for k, v in hist.items()])
    with open(path, 'w', newline='') as fh:
        w = csv.writer(fh); w.writerow(header); w.writerows(rows)
    return rows

def load_tool_history(path):
    hist = {}
    if not os.path.exists(path): return hist
    with open(path) as fh:
        r = csv.reader(fh); next(r, None)
        for row in r:
            if len(row) == 5:
                d, by, proj, tool, count = row
                hist[(d, 'claude', by, proj, tool)] = int(count)
            elif len(row) == 6:
                d, runtime, by, proj, tool, count = row
                hist[(d, runtime, by, proj, tool)] = int(count)
    return hist
def merge_tool_history(existing, fresh):
    hist = {k: v for k, v in existing.items() if (k[0], k[1], k[2], k[3]) not in tool_scanned_groups}
    hist.update(fresh)
    return sorted([*k, v] for k, v in hist.items())

tool_rows = merge_tool_history(load_tool_history(os.path.join(out, 'history.csv')), scan)
with open(os.path.join(out, 'history.csv'), 'w', newline='') as fh:
    w = csv.writer(fh)
    w.writerow(['date', 'runtime', 'triggered_by', 'project', 'tool', 'count'])
    w.writerows(tool_rows)
inj_rows = merge_write(os.path.join(out, 'injects.csv'),
    ['date', 'triggered_by', 'project', 'source', 'count'],
    load(os.path.join(out, 'injects.csv'), 5), inj)
json.dump(LEARNED, open(LEARN_PATH, 'w'), indent=0, sort_keys=True)  # persist learned attributions

# --- 3. build dashboard from full history; default view = trailing VIEW_DAYS ---
all_dates = sorted({r[0] for r in tool_rows})
today = datetime.date.today()
default_from = max(all_dates[0], (today - datetime.timedelta(days=view_days)).isoformat()) if all_dates else today.isoformat()
meta = {
    'rows': tool_rows,
    'skill_inv': skill_inv,
    'injects': inj_rows,
    'default_from': default_from,
    'view_days': view_days,
    'generated': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
    'total': sum(r[5] for r in tool_rows),
}
data_js = 'const DATA=' + json.dumps(meta, ensure_ascii=False, separators=(',', ':')) + ';'
tpl = open(os.path.join(src, 'dashboard.template.html')).read()
open(os.path.join(out, 'dashboard.html'), 'w').write(tpl.replace('/*__DATA__*/', data_js))

span = f'{all_dates[0]}..{all_dates[-1]}' if all_dates else '(empty)'
print(f'history.csv: {len(tool_rows)} rows, {meta["total"]} calls')
print(f'injects.csv: {len(inj_rows)} rows; inject sources: {sorted({r[3] for r in inj_rows})}')
print(f'dashboard.html: {os.path.getsize(os.path.join(out,"dashboard.html"))//1024} KB  span {span}  (default view: last {view_days}d)')
PY

DASH="$OUT/dashboard.html"
echo "→ $DASH"
if [ "${TOOLYTICS_OPEN:-1}" != "0" ]; then
  open "$DASH" 2>/dev/null || xdg-open "$DASH" 2>/dev/null || true
fi
