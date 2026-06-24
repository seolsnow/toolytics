# Codex Tool Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggregate local Codex tool calls with Claude Code calls in one filterable toolytics dashboard.

**Architecture:** Migrate only history.csv to add a runtime field, scan Codex session JSONL into it, and apply a client-side runtime filter to tool rows. Claude token, injection, and skill datasets remain unchanged.

**Tech Stack:** Bash, embedded Python standard library, self-contained HTML/CSS/JavaScript, CSV.

## Global Constraints

- Existing five-column history.csv rows migrate as runtime=claude.
- Scan ~/.codex/sessions/**/*.jsonl; add no dependency or network call.
- A session is agent when session_meta has thread_source == "subagent" or source.subagent; otherwise main.
- Count only named response_item function_call and custom_tool_call payloads.
- This release collects no Codex tokens, costs, injections, or skill inventory.
- Preserve the unrelated TEMP_REVIEW_FOLLOWUPS.md.

---

### Task 1: Add an end-to-end Codex fixture to the self-check

**Files:**
- Modify: build.sh:20-81

**Interfaces:**
- Consumes: build.sh executed with HOME, TOOLYTICS_HOME, and TOOLYTICS_OPEN=0 overridden.
- Produces: a failing self-check until named Codex main and agent calls reach history.csv.

- [ ] **Step 1: Add the failing fixture assertion**

Pass "$SRC/build.sh" as sys.argv[1] to the self-check Python block. Add this exact test after the current cache assertions:

    import tempfile, subprocess
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
             'payload': {'cwd': home, 'thread_source': 'subagent', 'source': {'subagent': {}}}},
            {'timestamp': '2026-06-25T01:00:03Z', 'type': 'response_item',
             'payload': {'type': 'custom_tool_call', 'name': 'exec'}},
        ]
        for name, rows in [('main.jsonl', main_rows), ('agent.jsonl', agent_rows)]:
            with open(os.path.join(root, name), 'w') as fh:
                fh.writelines(json.dumps(row) + '\n' for row in rows)
        out = os.path.join(home, 'out')
        subprocess.run([script, '1'], check=True, env={**os.environ, 'HOME': home,
                       'TOOLYTICS_HOME': out, 'TOOLYTICS_OPEN': '0'})
        with open(os.path.join(out, 'history.csv')) as fh:
            got = list(csv.DictReader(fh))
        assert {(r['runtime'], r['triggered_by'], r['tool']) for r in got} == {
            ('codex', 'main', 'exec_command'), ('codex', 'agent', 'exec')}

- [ ] **Step 2: Verify RED**

Run: ./build.sh --selfcheck

Expected: the fixture assertion fails because production has no Codex scanner or runtime field.

### Task 2: Collect Codex calls and migrate the history schema

**Files:**
- Modify: build.sh:2-7, 207-291, 335-356

**Interfaces:**
- Consumes: Codex records with timestamp, type, and payload.
- Produces: history.csv rows shaped as (date, runtime, triggered_by, project, tool, count).

- [ ] **Step 1: Add runtime-aware collector state**

Replace the Claude-only counter and covered-group state with:

    scan = collections.Counter()       # (date, runtime, by, project, tool) -> count
    tool_scanned_groups = set()        # (date, runtime, by, project)
    claude_scanned_groups = set()      # (date, by, project), tokens/injects only

In the existing Claude loop, add both covered groups and change the tool key:

    tool_scanned_groups.add((d, 'claude', by, proj))
    claude_scanned_groups.add((d, by, proj))
    scan[(d, 'claude', by, proj, n)] += 1

- [ ] **Step 2: Add the minimal Codex scanner**

Add after the Claude scan:

    def codex_context(path):
        by, cwd = 'main', None
        for line in open(path, errors='ignore'):
            try: record = json.loads(line)
            except Exception: continue
            payload = record.get('payload') or {}
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
            payload = record.get('payload') or {}
            if record.get('type') != 'response_item': continue
            if payload.get('type') not in ('function_call', 'custom_tool_call'): continue
            name = payload.get('name')
            if name: scan[(d, 'codex', by, proj, name)] += 1

- [ ] **Step 3: Read legacy rows and merge on the new group**

Replace the tool-history load/merge with:

    def load_tool_history(path):
        history = {}
        if not os.path.exists(path): return history
        with open(path) as fh:
            reader = csv.reader(fh); next(reader, None)
            for row in reader:
                if len(row) == 5:
                    d, by, proj, tool, count = row
                    history[(d, 'claude', by, proj, tool)] = int(count)
                elif len(row) == 6:
                    d, runtime, by, proj, tool, count = row
                    history[(d, runtime, by, proj, tool)] = int(count)
        return history

    def merge_tool_history(existing, fresh):
        history = {key: value for key, value in existing.items()
                   if (key[0], key[1], key[2], key[3]) not in tool_scanned_groups}
        history.update(fresh)
        return sorted([*key, value] for key, value in history.items())

    tool_rows = merge_tool_history(load_tool_history(os.path.join(out, 'history.csv')), scan)
    with open(os.path.join(out, 'history.csv'), 'w', newline='') as fh:
        writer = csv.writer(fh)
        writer.writerow(['date', 'runtime', 'triggered_by', 'project', 'tool', 'count'])
        writer.writerows(tool_rows)

Keep token and injection merges on claude_scanned_groups, so a Codex scan cannot replace Claude data.

- [ ] **Step 4: Verify GREEN**

Run: ./build.sh --selfcheck

Expected: selfcheck OK: all assertions passed, including the two fixture rows.

- [ ] **Step 5: Commit**

    git add build.sh
    git commit -m "feat: collect Codex tool calls"

### Task 3: Add the dashboard Runtime filter

**Files:**
- Modify: dashboard.template.html:145-240, 249-521

**Interfaces:**
- Consumes: DATA.rows as [date, runtime, triggered_by, project, tool, count].
- Produces: runtime-filtered tools, MCP, projects, daily series, and direct/delegated totals.

- [ ] **Step 1: Add the Runtime segmented control**

Place this before Triggered by:

    <div class="fld"><label>Runtime</label>
      <div class="seg" id="f-runtime">
        <button data-v="all" aria-pressed="true">All</button>
        <button data-v="claude">Claude</button>
        <button data-v="codex">Codex</button>
      </div>
    </div>

Update the eyebrow/footer to name both products and both transcript roots.

- [ ] **Step 2: Define row shapes and filters**

Replace the single column layout with:

    const COL={date:0,runtime:1,by:2,proj:3,tool:4,n:5};
    const TCOL={date:0,by:1,proj:2,model:3,n:4};
    const ICOL={date:0,by:1,proj:2,source:3,n:4};
    const PROJECTS=[...new Set(ROWS.map(r=>r[COL.proj]))].sort();

    function passTool(r){return (S.runtime==='all'||r[COL.runtime]===S.runtime) &&
      (S.by==='all'||r[COL.by]===S.by) &&
      (allProj()||S.projs.has(r[COL.proj])) && r[COL.date]>=S.from && r[COL.date]<=S.to;}
    function passToken(r){return S.runtime!=='codex' && (S.by==='all'||r[TCOL.by]===S.by) &&
      (allProj()||S.projs.has(r[TCOL.proj])) && r[TCOL.date]>=S.from && r[TCOL.date]<=S.to;}
    function passInject(r){return S.runtime!=='codex' && (S.by==='all'||r[ICOL.by]===S.by) &&
      (allProj()||S.projs.has(r[ICOL.proj])) && r[ICOL.date]>=S.from && r[ICOL.date]<=S.to;}

Use COL for every tool aggregation and passToken/passInject for unchanged token/injection rows.

- [ ] **Step 3: Wire the control through state**

Add runtime:'all' to S, bind #f-runtime using the #f-by event pattern, include runtime in the paint signature, reset it to All, and use:

    const rows=ROWS.filter(passTool);

The Where rollup applies passTool while deliberately ignoring only the project filter.

- [ ] **Step 4: Verify generated data shape**

Run:

    tmp=$(mktemp -d)
    TOOLYTICS_HOME="$tmp" TOOLYTICS_OPEN=0 ./build.sh 30
    python3 - "$tmp/dashboard.html" <<'PY'
    import json, re, sys
    text = open(sys.argv[1]).read()
    data = json.loads(re.search(r'^const DATA=(.*);$', text, re.M).group(1))
    assert all(len(row) == 6 for row in data['rows'])
    PY

Expected: exit 0 and six-field rows.

- [ ] **Step 5: Commit**

    git add dashboard.template.html
    git commit -m "feat: filter dashboard by runtime"

### Task 4: Update documentation and verify the full change

**Files:**
- Modify: README.md:1-85
- Modify: AGENTS.md:1-150
- Modify: .claude-plugin/plugin.json:2-6

**Interfaces:**
- Consumes: completed collector and dashboard.
- Produces: accurate source, schema, direct/delegated, and scope documentation for version 0.1.5.

- [ ] **Step 1: Document the supported scope**

Document the two transcript roots, runtime CSV field, Codex subagent attribution, and the current exclusions (tokens, cost, hooks, skill inventory). Update the plugin description and version to 0.1.5.

- [ ] **Step 2: Run complete verification**

Run:

    ./build.sh --selfcheck
    tmp=$(mktemp -d)
    TOOLYTICS_HOME="$tmp" TOOLYTICS_OPEN=0 ./build.sh 30
    test -s "$tmp/history.csv"
    test -s "$tmp/dashboard.html"
    git diff --check HEAD
    git status --short

Expected: self-check passes; both artifacts exist; no whitespace errors; TEMP_REVIEW_FOLLOWUPS.md remains untracked.

- [ ] **Step 3: Commit**

    git add README.md AGENTS.md .claude-plugin/plugin.json
    git commit -m "docs: document Codex tracking"
