#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

worktree_path="$cwd/.claude/worktrees/$name"
branch_name="worktree-$name"

if [ -d "$cwd/.jj" ]; then
  git -C "$cwd" worktree add -b "$branch_name" "$worktree_path" HEAD >&2
else
  git -C "$cwd" worktree add -b "$branch_name" "$worktree_path" >&2
fi

echo "$worktree_path"
