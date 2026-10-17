#!/usr/bin/env bash
# Install the COPE agents, skill, and cope-wt for every project.
#   ./install.sh           symlink agents + skill into ~/.claude, cope-wt into ~/.local/bin
#   ./install.sh --hooks   also register the WorktreeCreate/WorktreeRemove/SubagentStop hooks and pin the
#                          subagent nesting depth in ~/.claude/settings.json (backed up first)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/.claude"

mkdir -p ~/.claude/agents ~/.claude/skills ~/.local/bin
for f in "$src"/agents/cope*.md; do
  ln -sfn "$f" ~/.claude/agents/"$(basename "$f")"
done
ln -sfn "$src/skills/cope" ~/.claude/skills/cope
ln -sfn "$here/bin/cope-wt" ~/.local/bin/cope-wt
echo "Linked agents: $(cd "$src/agents" && ls cope*.md | tr '\n' ' ')"
echo "Linked skill: cope, and ~/.local/bin/cope-wt"

if [[ ${1:-} == --hooks ]]; then
  command -v jq >/dev/null || { echo "jq is required for --hooks" >&2; exit 1; }
  settings=~/.claude/settings.json
  [[ -f $settings ]] || echo '{}' > "$settings"
  cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
  wt="$HOME/.local/bin/cope-wt"
  tmp=$(mktemp)
  jq --arg c "$wt hook-create" --arg r "$wt hook-remove" --arg u "$wt hook-usage" '
    def without_cope: map(select((.hooks // []) | all(.command | tostring | contains("cope-wt") | not)));
    .hooks.WorktreeCreate = ((.hooks.WorktreeCreate // []) | without_cope) + [{hooks: [{type: "command", command: $c}]}]
    | .hooks.WorktreeRemove = ((.hooks.WorktreeRemove // []) | without_cope) + [{hooks: [{type: "command", command: $r}]}]
    | .hooks.SubagentStop = ((.hooks.SubagentStop // []) | without_cope) + [{hooks: [{type: "command", command: $u}]}]
    | .env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = (.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH // "3")
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  echo "Registered worktree hooks and nesting depth in $settings (backup saved alongside)"
fi
