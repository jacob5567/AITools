#!/usr/bin/env bash
# Exercise bin/cope-wt end to end in throwaway repos. Needs git, jq, and python3 (with venv).
#   tests/cope-wt.test.sh
set -uo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/cope-wt"
S=$(mktemp -d "${TMPDIR:-/tmp}/cope-wt-test.XXXXXX")
trap 'rm -rf "$S"' EXIT
export COPE_RUN=test-default   # keep runs independent of any Claude Code session running the tests
export XDG_CACHE_HOME=$S/cache
R=$S/repo2; rm -rf "$R" "$S/cache"; mkdir -p "$R"; cd "$R"
ok() { echo "ok   - $*"; }; bad() { echo "FAIL - $*"; FAILS=$((FAILS+1)); }; FAILS=0

git init -q; printf 'node_modules/\n' > .gitignore; mkdir -p node_modules/dep; echo dep > node_modules/dep/x
printf 'def add(a, b):\n    return a - b\n' > calc.py
git add -A; git -c user.name=t -c user.email=t@t commit -qm init
printf 'from calc import add\nassert add(2, 3) == 5\n' > test_oracle.py      # untracked oracle written before snapshot
before=$(git status --porcelain; git ls-files -s)

$W snapshot >/dev/null && ok snapshot || bad snapshot
for i in 1 2 3 4; do echo "{\"name\":\"agent-$i\",\"cwd\":\"$R\"}" | $W hook-create >/dev/null 2>&1; done
mapfile -t WT < <($W list)
[[ ${#WT[@]} == 4 ]] && ok "4 worktrees" || bad "worktrees: ${#WT[@]}"
[[ -f ${WT[0]}/test_oracle.py && -f ${WT[0]}/node_modules/dep/x ]] && ok "untracked file + ignored deps present" || bad "worktree contents"
[[ $before == "$(git status --porcelain; git ls-files -s)" ]] && ok "main tree and index untouched" || bad "main tree changed"

sed -i 's/a - b/a + b/' "${WT[0]}/calc.py"
sed -i 's/a - b/a  +  b/' "${WT[1]}/calc.py"                     # whitespace-only variant of WT0
sed -i 's/a - b/b + a/' "${WT[2]}/calc.py"                       # distinct correct fix
sed -i 's/a - b/a - b/' "${WT[3]}/calc.py"; echo 'assert True' > "${WT[3]}/test_oracle.py"   # cheats

out=$($W verify --checks 'python3 test_oracle.py' --oracle test_oracle.py)
echo "$out" | sed 's/^/     | /'
grep -q '^PASSED 3/4' <<<"$out" && ok "3/4 pass" || bad "pass count"
grep -q '^TAMPERED .*agent-4' <<<"$out" && ok "oracle tampering caught" || bad "tamper"
grep -q '^DECISION: PICK ' <<<"$out" && ok "decision: PICK for distinct passers" || bad "decision pick: $(grep DECISION <<<"$out")"
[[ $($W verify --checks 'python3 test_oracle.py' --oracle test_oracle.py | grep -c '^PASS ') == 0 ]] && ok "re-verify skips already-verified candidates" || bad "re-verify"
mapfile -t SH < <(awk '/^PASS /{print $2}' <<<"$out")

[[ $($W diffs --summary "${SH[0]}" "${SH[1]}") == IDENTICAL* ]] && ok "whitespace-identical detected" || bad identical
[[ $($W diffs --summary "${SH[@]}") == DISTINCT\ 2* ]] && ok "distinct detected" || bad distinct
COPE_MAX_DIFF_LINES=1 $W diffs "${SH[@]}" | grep -q '^TOO-LARGE' && ok "too-large shortcut" || bad too-large
$W diffs "${SH[@]}" | grep -c '^===== CANDIDATE' | grep -qx 3 && ok "full diffs" || bad "full diffs"

$W apply "${SH[2]}" >/dev/null && grep -q 'b + a' calc.py && ok "apply to main tree" || bad apply
python3 test_oracle.py && ok "main tree passes oracle" || bad "main oracle"
git diff --cached --quiet && ok "apply left index unstaged" || bad "index staged"

git checkout -q calc.py; echo '# user edit' >> calc.py
$W apply "${SH[0]}" >/dev/null 2>&1 && bad "conflict not detected" || ok "conflict detected, patch saved"

$W cleanup >/dev/null
[[ $(git worktree list | wc -l) == 1 ]] && ok "cleanup removed worktrees" || bad cleanup
[[ -z $(git for-each-ref refs/cope) ]] && ok "snapshot ref removed" || bad "snapshot ref kept"

out=$(echo "{\"name\":\"plain\",\"cwd\":\"$R\"}" | $W hook-create 2>/dev/null)
[[ $out == "$R/.claude/worktrees/plain" ]] && git rev-parse -q --verify refs/heads/worktree-plain >/dev/null \
  && ok "no-snapshot fallback = branch worktree in .claude/worktrees" || bad "fallback: $out"
echo "{\"worktree_path\":\"$out\"}" | $W hook-remove && [[ ! -d $out ]] && ok hook-remove || bad hook-remove
echo '{"worktree_path":"/nonexistent"}' | $W hook-remove && ok "hook-remove tolerates missing path" || bad "hook-remove missing"

# Python editable-install guard: package importable from outside the worktree must be ENV-FAIL.
P=$S/pyrepo; rm -rf "$P"; mkdir -p "$P/mypkg"; cd "$P"; git init -q
printf '[project]\nname = "mypkg"\nversion = "0"\n' > pyproject.toml; echo 'V = 1' > mypkg/__init__.py
git add -A; git -c user.name=t -c user.email=t@t commit -qm init
$W snapshot >/dev/null; echo "{\"name\":\"py1\",\"cwd\":\"$P\"}" | $W hook-create >/dev/null 2>&1
pwt=$($W list); echo 'V = 2' > "$pwt/mypkg/__init__.py"
out=$($W verify --checks 'python3 -c "import mypkg; assert mypkg.V == 2"')
grep -q '^PASS ' <<<"$out" && ok "python: worktree code is what gets imported" || { bad "python import"; echo "$out"; }
mkdir -p "$S/shadow/mypkg"; echo 'V = 1' > "$S/shadow/mypkg/__init__.py"
# Simulate an editable install that wins over PYTHONPATH via a sitecustomize meta_path hook.
mkdir -p "$S/site"; cat > "$S/site/sitecustomize.py" <<EOF
import sys; sys.path.insert(0, "$S/shadow")
EOF
out=$(env PYTHONPATH="$S/site" $W verify --all --checks 'true')
grep -q '^ENV-FAIL ' <<<"$out" && ok "python: shadowed import -> ENV-FAIL" || { bad "python guard"; echo "$out"; }
$W cleanup >/dev/null

# Realistic editable install: a .pth in a copied venv pointing at the main tree must lose to the worktree.
cd "$P"; echo '.venv/' > .gitignore; git add .gitignore; git -c user.name=t -c user.email=t@t commit -qm ign
python3 -m venv .venv && sp=$(.venv/bin/python -c 'import site;print(site.getsitepackages()[0])')
echo "$P" > "$sp/_editable_mypkg.pth"
$W snapshot >/dev/null; echo "{\"name\":\"py2\",\"cwd\":\"$P\"}" | $W hook-create >/dev/null 2>&1
pwt=$($W list); echo 'V = 2' > "$pwt/mypkg/__init__.py"
out=$($W verify --checks '.venv/bin/python -P -c "import mypkg; assert mypkg.V == 2"')
grep -q '^PASS ' <<<"$out" && ok "python: editable .pth to main tree is overridden" || { bad "editable .pth"; echo "$out"; }
$W cleanup >/dev/null

# Batches: 2 failing candidates, then 1 more that passes -> decision counts across batches.
cd "$R"; git checkout -q calc.py; $W snapshot >/dev/null
for i in 1 2; do echo "{\"name\":\"b-$i\",\"cwd\":\"$R\"}" | $W hook-create >/dev/null 2>&1; done
out=$($W verify --checks 'python3 test_oracle.py')
grep -q '^DECISION: NONE-PASSED' <<<"$out" && ok "batch 1: NONE-PASSED" || bad "batch1: $(tail -2 <<<"$out")"
echo '{"name":"b-3","cwd":"'"$R"'"}' | $W hook-create >/dev/null 2>&1
sed -i 's/a - b/a + b/' "$($W list | grep b-3)/calc.py"
out=$($W verify --checks 'python3 test_oracle.py')
[[ $(grep -cE '^(PASS|FAIL) ' <<<"$out") == 1 ]] && ok "batch 2 verifies only the new candidate" || bad "batch2 count"
grep -q '^PASSED 1/3 (this batch: 1/1)' <<<"$out" && grep -q '^DECISION: APPLY ' <<<"$out" && ok "batch 2: APPLY with 1/3 overall" || bad "batch2: $(tail -2 <<<"$out")"
out=$($W verify --all --apply --checks 'python3 test_oracle.py')
grep -q '^APPLIED ' <<<"$out" && grep -q '^CLEANED 3' <<<"$out" && grep -q 'a + b' calc.py && [[ -z $($W list) ]] \
  && ok "verify --apply applies and cleans up in one call" || bad "verify --apply: $(tail -3 <<<"$out")"
git checkout -q calc.py

# Per-run isolation: two sessions in one repo.
COPE_RUN=sessA $W snapshot >/dev/null; COPE_RUN=sessB $W snapshot >/dev/null
pa=$(echo '{"name":"x","cwd":"'"$R"'","session_id":"sessA"}' | $W hook-create 2>/dev/null)
pb=$(echo '{"name":"x","cwd":"'"$R"'","session_id":"sessB"}' | $W hook-create 2>/dev/null)
[[ $pa != "$pb" && $(COPE_RUN=sessA $W list) == "$pa" && $(COPE_RUN=sessB $W list) == "$pb" ]] && ok "runs get separate worktree dirs" || bad "isolation: $pa $pb"
pc=$(echo '{"name":"y","cwd":"'"$R"'","session_id":"unknown"}' | $W hook-create 2>/dev/null)
[[ $pc == "$R/.claude/worktrees/y" ]] && ok "ambiguous session with 2 runs -> plain fallback" || bad "ambiguous: $pc"
git worktree remove --force "$pc"; git branch -qD worktree-y
COPE_RUN=sessA $W cleanup >/dev/null
[[ -d $pb && -z $(COPE_RUN=sessA $W list) ]] && git rev-parse -q --verify refs/cope/$(printf sessB | sha1sum | cut -c1-10)/snapshot >/dev/null \
  && ok "cleanup of run A leaves run B intact" || bad "cleanup isolation"
pd=$(echo '{"name":"z","cwd":"'"$R"'","session_id":"unknown"}' | $W hook-create 2>/dev/null)
[[ $(dirname "$pd") == "$(dirname "$pb")" ]] && ok "unknown session with exactly 1 run -> that run" || bad "single-run fallback: $pd"
COPE_RUN=sessB $W cleanup >/dev/null; $W cleanup --all >/dev/null
[[ $(git worktree list | wc -l) == 1 && -z $(git for-each-ref refs/cope) ]] && ok "cleanup --all" || bad "cleanup --all"

# Brief: saved in the git dir, readable from a worktree, survives a mid-run cleanup, removed by --final.
cd "$R"; COPE_RUN=br $W snapshot >/dev/null
bp=$(printf 'FILES: calc.py\n' | COPE_RUN=br $W brief save)
[[ $bp == "$(git rev-parse --path-format=absolute --git-common-dir)/cope/"*/brief.md && $(cat "$bp") == "FILES: calc.py" ]] && ok "brief saved in git dir" || bad "brief save: $bp"
[[ -z $(git status --porcelain --ignored | grep -i cope) ]] && ok "brief invisible to git status" || bad "brief shows in status"
COPE_RUN=br $W cleanup >/dev/null; [[ $(COPE_RUN=br $W brief path) == "$bp" ]] && ok "brief survives mid-run cleanup" || bad "brief lost on cleanup"
COPE_RUN=br $W cleanup --final >/dev/null; COPE_RUN=br $W brief path >/dev/null 2>&1 && bad "brief kept after --final" || ok "cleanup --final removes brief"

# Profile block parsing, and .worktreeinclude merged with the default deps.
cd "$R"
[[ $($W profile) == "PROFILE: none" ]] && ok "profile: none without CLAUDE.md" || bad "profile none"
cat > CLAUDE.md <<'EOF'
# Notes
Keep this line.
<!-- cope:profile -->
## Build and test notes (maintained by COPE; edit freely)
- Check: `dotnet build -c Release -p:CopyToProfile=false`
- Test signal: compile-only: builds, but behavior is only checked in-game
- Oracle: not-possible: code runs only inside the game
- Hazards: plain dotnet build copies the DLL into the r2modman profile
- Worktree needs: Directory.Build.props.user
- Baseline: pass (2026-10-16, abc1234)
<!-- /cope:profile -->
EOF
out=$($W profile)
grep -qx 'CHECK: dotnet build -c Release -p:CopyToProfile=false' <<<"$out" && grep -qx 'SIGNAL: compile-only' <<<"$out" \
  && grep -q '^ORACLE: not-possible' <<<"$out" && grep -q '^HAZARDS: plain dotnet' <<<"$out" && grep -q '^BASELINE: pass' <<<"$out" \
  && ok "profile: fields parsed" || { bad "profile parse"; echo "$out"; }
printf 'local.user\n' > .worktreeinclude; printf '*.user\n' >> .gitignore; echo cfg > local.user
$W snapshot >/dev/null; wt=$(echo '{"name":"inc","cwd":"'"$R"'"}' | $W hook-create 2>/dev/null)
[[ -f $wt/local.user && -f $wt/node_modules/dep/x ]] && ok ".worktreeinclude merged with default deps" || bad "worktreeinclude merge"
$W cleanup --final >/dev/null; rm -f CLAUDE.md .worktreeinclude local.user; git checkout -q .gitignore

# Usage hook: fake transcript with a duplicated streamed message id.
T=$S/fake-transcript.jsonl
cat > "$T" <<'EOF'
{"type":"assistant","message":{"id":"m1","model":"claude-haiku-5-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":3}}}
{"type":"assistant","message":{"id":"m1","model":"claude-haiku-5-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":40}}}
{"type":"assistant","message":{"id":"m2","model":"claude-haiku-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":900,"output_tokens":7}}}
EOF
export COPE_USAGE_LOG=$S/usage.tsv; rm -f "$COPE_USAGE_LOG"
out=$(echo '{"agent_type":"cope-executor","agent_transcript_path":"'"$T"'","session_id":"abcdef123","cwd":"/x/myrepo"}' | $W hook-usage); rc=$?
echo '{"agent_type":"Explore","agent_transcript_path":"'"$T"'"}' | $W hook-usage
echo 'not json' | $W hook-usage; rc2=$?
[[ $rc == 0 && $rc2 == 0 && -z $out ]] && ok "hook-usage silent, always exit 0" || bad "hook-usage rc=$rc/$rc2 out=$out"
[[ $(tail -n +2 "$COPE_USAGE_LOG" | wc -l) == 1 ]] && tail -1 "$COPE_USAGE_LOG" | grep -qP '\tcope-executor\thaiku-5-5\t7\t110\t900\t47$' \
  && ok "usage: deduped by message id, non-cope agents skipped" || { bad "usage row"; cat "$COPE_USAGE_LOG"; }
$W report | grep -q 'TOTAL .*haiku-5-5 .*out=     47' && ok "report totals" || { bad report; $W report; }

echo; ((FAILS)) && { echo "$FAILS failure(s)"; exit 1; } || echo "all passed"
