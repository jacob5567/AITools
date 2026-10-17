# COPE agents for Claude Code

This is a token-saving agent cascade based on [*Efficient LLM Collaboration via Planning*](https://arxiv.org/html/2506.11578v5) (COPE). In the paper, the large model mostly writes **short plans**, and cheap models do the bulk of the generation. The large model executes only when a mechanical confidence check fails. The paper reports roughly 26-74% lower paid-API cost at comparable accuracy.

```
interpret  Sonnet (high effort) rewrites the request: clear TASK, ACCEPTANCE, ASSUMPTIONS;
           classifies question/change, trivial/small/larger, ambiguous → ask
profile first run in a repo: Sonnet profiler writes a build/test block into CLAUDE.md
        (safe check command, test signal, hazards, baseline); later runs read it for free
weak    compile-only / no tests → Opus plan (if not small) → 1× Sonnet → builds? → apply
        + a manual test checklist; no Haiku sampling or oracle
triage  trivial → 1× Haiku · small → 1× Sonnet   (one worktree, verified; on failure → setup, then S2)
setup   Sonnet scout → brief;  Sonnet oracle → shared failing tests;  cope-wt snapshot
S1      2× Haiku in worktrees (+2 more if none pass)                  accept as soon as ≥1 passes
S2      Opus writes a 1–2 sentence guideline → 2× (+2) Sonnet          accept as soon as ≥1 passes
S3      the same Opus guideline → Opus executes in the main tree       final fallback
select  one passer → apply · identical → apply · distinct → Sonnet picker → apply → cleanup
```

## Pieces

| File | Model | Job |
|---|---|---|
| `.claude/agents/cope.md` | Sonnet | Orchestrator. It has only `Bash` and an `Agent` tool limited to the cope agents, so it can't read code. It skips CLAUDE.md, passes the brief by path, and chains its shell steps. |
| `.claude/agents/cope-interpreter.md` | Sonnet (high effort) | Runs first on every request. It rewrites the request into a clear task with acceptance criteria and assumptions, keeping exact names and strings word for word. It classifies the request, so triage happens at high effort, not in the low-effort orchestrator. |
| `.claude/agents/cope-profiler.md` | Sonnet | Runs once per repo. It finds the safe check command, what a pass proves (`tests` / `compile-only` / `none`), build side effects, the gitignored files builds need, and today's baseline. It writes them to a marked block in CLAUDE.md and adds `.worktreeinclude` entries. |
| `.claude/agents/cope-scout.md` | Sonnet (briefs) / Haiku (voting) | Saves a compact brief (files, conventions, check commands) with `cope-wt brief save`, and replies with only its path, the checks, and whether existing tests cover the target. In question mode, Haiku scouts vote. |
| `.claude/agents/cope-oracle.md` | Sonnet | Writes the shared acceptance tests that define a pass, before any code exists. |
| `.claude/agents/cope-executor.md` | Haiku (S1) / Sonnet (S2, small tasks) | Implements the change in its own worktree. The model is overridden per stage. |
| `.claude/agents/cope-planner.md` | Opus | Writes a 1-2 sentence guideline, which is reused in Stage 3. No code and no CLAUDE.md, so it stays small. |
| `.claude/agents/cope-executor-large.md` | Opus | Final fallback. Gets only the Opus guideline, never Haiku's goals. |
| `.claude/agents/cope-picker.md` | Sonnet | Picks the cleanest of several *distinct* passing candidates by reading their diffs. Skips CLAUDE.md. |
| `.claude/agents/cope-verifier.md` | Haiku | Finds the check commands. Verifies non-git and Stage 3 runs. |
| `bin/cope-wt` | none (shell) | Snapshot, worktree and usage hooks, brief storage, incremental verification with a `DECISION` line (`--apply` also applies and cleans up), cleanup, and token reports. Uses zero tokens. |
| `.claude/skills/cope/SKILL.md` | none | `/cope <task>` launcher. It has `context: fork` and `agent: cope`, so the cascade runs as a subagent. |

Effort levels are set explicitly in each agent's file, so they don't depend on how the cascade is launched:
- **low:** the orchestrator and the verifier, which do routing and mechanical checks.
- **medium:** the scout, the picker, the executor (both its Haiku and Sonnet runs), and the planner, which writes 1–2 sentences.
- **high:** the interpreter, the profiler, the test-writer, and the Opus fallback, whose output decides correctness or runs only after cheaper attempts failed.

In test runs, thinking was 0–11% of each agent's output, so these levels are mostly about predictability, not cost.

## Install and use

**Requirements:**
- Claude Code 2.1.301 or later. This needs nested subagents, the `WorktreeCreate`/`SubagentStop` hooks, and the `omitClaudeMd` and `Agent(...)` frontmatter.
- Linux with GNU coreutils (`cp --reflink`, `sha1sum`, `timeout`). macOS's stock BSD tools aren't supported.
- `git`, `jq`, `bash`, and `python3`.
- Optional: a reflink-capable filesystem (btrfs, XFS) for instant dependency copies. Elsewhere, dependencies are fully copied.

```bash
git clone https://github.com/jacob5567/AITools && cd AITools
./install.sh --hooks   # symlinks agents, skill, ~/.local/bin/cope-wt; registers the worktree + usage hooks
```

There are three ways to run it:
- **`/cope <task>`** from any session. Your conversation only receives the final report.
- **`claude --agent cope`** makes the whole session the orchestrator. Use it when subagent nesting is capped, or when you want to watch each stage.
- **Ask your main session** to "use the cope agent".

Two logs help with tuning:
- **`~/.claude/cope-log.tsv`** gets one line per run, written by the orchestrator: the path taken, candidates spawned, the accepting stage, and the models used.
- **`~/.claude/cope-usage.tsv`** gets one line per cope agent and model, written by the `SubagentStop` hook: input, cache-write, cache-read, and output tokens. To see the totals, run `cope-wt report [N]`, which summarizes the last N runs per agent and model.

## Projects without tests

The cascade accepts the first candidate that passes, so it's only as good as its checks. On the first `/cope` in a repo, the profiler records what a pass means, and the orchestrator routes on it:
- **`tests`:** the normal cascade.
- **`compile-only` or `none`:** for example, game mods tested in-game, or UI checked by eye. Haiku sampling would just accept the first attempt that builds. These repos get one Sonnet attempt instead, guided by an Opus plan when the task isn't small. The executor is told not to add a test framework, and the report starts with `UNVERIFIED BEHAVIOR` and a manual test checklist.
- **A failing baseline** stops the run with `BASELINE-FAIL`, unless the task is to fix those failures.
- **Build side effects** found by the profiler, like a post-build copy into a mod-manager profile, are folded into the profile's `Check:` command. Every agent is told to build only with that command.

The profile block is plain Markdown between `<!-- cope:profile -->` markers, so you can edit it. Delete it to force a re-profile. `cope-wt profile` prints its fields.

## How worktree sampling works

- **The brief** is stored in the main repo's git directory (`.git/cope/<run>/brief.md`), so every worktree can read it and git and test runners never see it. Mid-run cleanups keep it, and `cleanup --final` removes it.
- **Runs are per session.** The snapshot ref (`refs/cope/<run>/snapshot`) and the worktree folder (`~/.cache/cope-worktrees/<repo>/<run>/`) are keyed by the Claude Code session ID. That way, `/cope` runs in the same repo from different sessions never touch each other's candidates. If the hook can't match a session but exactly one fresh run exists, it uses that run. Each decision is written to `~/.cache/cope-worktrees/hook.log`.
- **The snapshot.** `cope-wt snapshot` commits your working tree, including uncommitted and untracked files, using a throwaway index. Your index and files are never touched.
- **The hooks.** The `WorktreeCreate` hook (`cope-wt hook-create`) builds each `isolation: "worktree"` subagent's tree from that snapshot, outside the repo, so your test runners never discover the copies.
- **Dependencies.** Gitignored dependency folders are copied with `cp --reflink=auto`. That's instant and nearly free on btrfs or XFS, and a full copy elsewhere. The folders come from `.worktreeinclude` (one path or glob per line), plus by default `node_modules .venv venv vendor target`.
- **Other worktree uses.** When no fresh snapshot exists (none in the last 12 h), the hook behaves like a plain worktree: branch `worktree-<name>` from **HEAD** in `.claude/worktrees/<name>`. One difference: Claude Code's built-in default starts from `origin/<default-branch>`, not HEAD.
- **Verification.**
  - `cope-wt verify` checks only candidates it hasn't seen in this run, so a second batch doesn't re-test the first.
  - It ends with a `DECISION:` line covering every candidate so far: `APPLY <sha>`, `PICK <shas>`, or `NONE-PASSED`.
  - Each candidate is committed *before* the checks run, so generated artifacts don't count. Build caches like `__pycache__` and `.pytest_cache` are always excluded.
  - Candidates that edit the oracle tests are disqualified (`TAMPERED`).
- **Python editable installs.** A copied `.venv` with `pip install -e` would import your **main** tree's code. `verify` puts the worktree first on `PYTHONPATH` and checks where the package actually imports from. If it resolves outside the worktree, the candidate is `ENV-FAIL`, never `PASS`.
- **Applying the winner.** `cope-wt apply` applies the winning diff to your working tree, leaving it unstaged. If you edited the same lines during the run, it stops with `CONFLICT` and saves the patch instead.

Knobs (environment variables):
- `COPE_CHECK_TIMEOUT`: seconds per check, default 600.
- `COPE_MAX_DIFF_LINES`: above this, the picker is skipped and the smallest diff wins. Default 1500.
- `COPE_SNAPSHOT_MAX_AGE`: default 43200 seconds.
- `COPE_USAGE_LOG`: default `~/.claude/cope-usage.tsv`.
- `COPE_LOG`: the per-run log that `cope-wt log` writes, default `~/.claude/cope-log.tsv`.
- `COPE_RUN`: overrides the run key.

## How this follows the paper

- **Code is accepted when one candidate passes.** The paper's rule for code: "If at least one output passes all test cases, a passing output is randomly selected." Its 0.75/0.5 consensus thresholds are for voting tasks. Because any pass ends the stage, candidates come in batches of 2, and the next batch only runs if nothing has passed.
- **No stage skipping.** The paper found that skipping Stage 1 cost more (248 vs 212) and scored lower (73.4% vs 74.4%). Hard problems gained the most from the full cascade. Stage 3 reuses the Stage 2 guideline, as in the paper.
- **Question mode uses the paper's thresholds at n=3.** Stage 1 needs 3/3 agreement (τ₁=0.75), and Stage 2 needs ≥2 of 3 (τ₂=0.5).
- **Three model tiers instead of two.** The paper's ordering still holds everywhere: Opus plans for Sonnet, Sonnet never plans for Opus, and Haiku goals never reach Opus. The paper keeps the small model in Stage 2; Sonnet there is a quality choice.
- **The pass signal is a shared test oracle,** standing in for the fixed tests in the paper's code benchmark. Without it, every candidate would only pass its own tests.
- **Selection:** the paper picks a passing output at random. Here, a Sonnet picker chooses, but only among *distinct* passing diffs. It never decides *whether* work passes; the paper's ablation found that large-model verification costs more and scores worse.
- **Where the paper's savings don't carry over:**
  - **The paper didn't count the small model's cost**, because its small models ran locally. Here every agent, Haiku included, is paid. Each one also re-reads its system prompt every time it starts.
  - **Small tasks therefore skip the cascade.** Size triage sends them to one Sonnet attempt. In testing, plain Sonnet matched Opus's quality on such a task for half the cost, while the full cascade cost more than plain Opus.

## Tests

End-to-end headless runs (`claude -p …`) in scratch Python repos, with the hooks passed through `--settings`. Quality was scored against hidden tests that no agent saw.

| Task | Plain Sonnet | Plain Opus | `/cope`, first design (4×, τ=3/4) | `/cope`, current |
|---|---|---|---|---|
| slugify accents + new `truncate_words` (1 module) | $0.09 · 11/11 | $0.19 · 11/11 | $0.22 · 11/11 (Stage 1, 4/4) | **$0.10** · 11/11 (single-shot Sonnet) |
| `stats` CLI subcommand + library function + README (3 files) | $0.09 · 8/8 | $0.23 · 8/8 | — | **$0.12** · 8/8 (single-shot Sonnet) |
| same, forced into Code mode | | | | **$0.18** · 8/8 (scout, oracle, 2× Haiku 2/2, picker) |
| leaner orchestrator: first task, single-shot | | | | **$0.07** · 11/11 (4 orchestrator turns) |
| leaner orchestrator: Code mode, 2 runs | | | | **$0.175 / $0.186** · 8/8 |

What these runs show:
- **On small and medium tasks, the cascade's fixed overhead outweighs its savings.** That overhead is the orchestrator, scout, oracle, and each agent's system prompt. Size triage keeps `/cope` within about 10–30% of plain Sonnet and well under plain Opus, at equal quality.
- **Code mode is for tasks big enough that a direct Opus run would cost much more than about $0.20.**
- **The orchestrator is the largest single consumer.** The leaner version compared cold-cache to cold-cache:
  - output fell 24% (3.3k → 2.5k tokens),
  - cache reads fell about 6%, and cache writes about 8%,
  - executor prompts halved (about 1,450 → 650 characters).

  That's about 10–15% of the orchestrator's cost. Its first turn (about 8k tokens) is always a cache write, because `/cope` runs are rarely within the 5-minute cache lifetime. `cope-wt report` shows where tokens go on your own tasks.
- **Earlier runs also exercised:**
  - the trivial path (Haiku, about $0.03),
  - a forced Stage 2 (Opus guideline → Sonnet candidates, about $0.30),
  - two concurrent `/cope` sessions, both resolved by session (`hook.log`).
- **A real bug was fixed:** the Agent tool runs subagents in the background by default, so `cope.md` requires `run_in_background: false`.
- **Untested:** the `DEPTH-LIMIT` branch, because a forked `/cope` still spawned workers with the depth cap at 1.

Run the `cope-wt` test suite with `tests/cope-wt.test.sh`. It builds throwaway repos in a temp dir and exits non-zero on failure. `bin/cope-wt` has a 46-check scripted test against throwaway repos, covering:
- the snapshot of dirty and untracked state, with the main tree and index left untouched,
- dependency copying,
- pass counting, oracle tampering, and `DECISION` lines (APPLY, PICK, NONE-PASSED),
- incremental batches,
- identical, distinct, and too-large diffs,
- apply, conflicts, and cleanup,
- per-run isolation and its fallbacks, and `cleanup --all`,
- the plain-worktree fallback and hook-remove,
- both Python import cases,
- the usage hook (dedupe, filtering, always exit 0, waiting for a still-streaming final message without blocking) and the report,
- brief storage (git-dir location, surviving mid-run cleanup, `--final`) and `verify --apply`,
- profile parsing, and `.worktreeinclude` merged with the default dependency list.

## License

[GPL-3.0](LICENSE).
