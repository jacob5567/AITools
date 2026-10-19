---
name: cope
description: Run a coding task or codebase question through the COPE cost cascade (arXiv 2506.11578). Haiku candidates run in parallel worktrees, then Opus-planned Sonnet candidates, then Opus as a last resort, with escalation decided by tests. Hands off to the `cope` orchestrator subagent, so only the final report lands in this conversation. Use for well-scoped implementation, bug-fix, or "where/how does X work" tasks when you want to save tokens without losing quality.
argument-hint: <task or question> [attachment paths]
---

Hand this request to the COPE cascade:

$ARGUMENTS

The `cope` agent sees nothing from this conversation or the IDE, only the prompt you send it. Before you call it, work out what the request points at. Use only what is already in this conversation. Don't open files or start on the task yourself.

- **ATTACHMENTS:** list the absolute path of each file the request depends on. That includes files the user attached or `@`-mentioned, images with a path, and a plan or document from this conversation. It also includes the file open in the IDE or the current selection (`<ide_opened_file>`, `<ide_selection>`), when the request refers to it ("this plan", "this file", "here"). For a selection, add its line range after the path.
- **CONTEXT:** what the request relies on from this conversation, briefly. Quote word for word anything it refers to that exists only here ("the bug we found", "the option we discussed"). Say what is already done, for example "steps 1 to 3 are committed (`479955b`)". List constraints the user set or that hold for this work, such as a conventions file to follow or "don't commit". Don't add requirements of your own. Leave this out when the request stands on its own.
- **An image pasted without a path:** if the request depends on it, transcribe everything legible in it word for word under `ATTACHMENT (inline image, transcribed):`.

Then call the Agent tool once, with `subagent_type: "cope"` and `run_in_background: false`. The prompt is the request above verbatim, followed by any `ATTACHMENTS:`, `CONTEXT:`, and transcription blocks, and then this line: "Working directory: <the current project's absolute path>. Follow your protocol from triage through Finish, and reply with your final report only."

When it returns, relay its report to the user unchanged. Don't re-check its work with `git diff`, greps, or builds: the cascade already ran the project's checks on exactly the change it applied, and each extra turn here re-reads this whole conversation. If it says `NEEDS-CLARIFICATION`, pass the question on.
