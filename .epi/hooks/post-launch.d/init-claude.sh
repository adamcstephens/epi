#!/usr/bin/env bash

"$EPI_BIN" exec "$EPI_INSTANCE" -- nix profile install --accept-flake-config 'github:numtide/llm-agents.nix#claude-code'

jq '{oauthAccount,userID,hasCompletedOnboarding}' <~/.claude.json | "$EPI_BIN" exec "$EPI_INSTANCE" -- "cat > .claude.json"
"$EPI_BIN" exec "$EPI_INSTANCE" -- mkdir .claude
cat ~/.claude/.credentials.json | "$EPI_BIN" exec "$EPI_INSTANCE" -- "cat > .claude/.credentials.json"
