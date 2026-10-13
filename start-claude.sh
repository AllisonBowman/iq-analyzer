#!/bin/zsh
# Starts Claude Code in this repo with the morning prompt (see MORNING_PROMPT.md and CLAUDE.md).
cd "$(dirname "$0")"
exec claude "$(cat MORNING_PROMPT.md)"
