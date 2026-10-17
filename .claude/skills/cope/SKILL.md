---
name: cope
description: Run a coding task or codebase question through the COPE cost cascade (arXiv 2506.11578). Haiku candidates run in parallel worktrees, then Opus-planned Sonnet candidates, then Opus as a last resort, with escalation decided by tests. Runs as the `cope` orchestrator subagent, so only the final report lands in this conversation. Use for well-scoped implementation, bug-fix, or "where/how does X work" tasks when you want to save tokens without losing quality.
context: fork
agent: cope
argument-hint: <task or question>
---

Run the COPE cascade on this task:

$ARGUMENTS

Working directory: the current project. Follow your protocol from triage through Finish, and reply with your final report only.
