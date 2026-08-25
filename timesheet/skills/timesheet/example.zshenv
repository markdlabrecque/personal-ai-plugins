# ~/.zshenv — loaded for every zsh invocation (interactive, scripts, subshells).
# Keep this file fast and side-effect-free: only exports, no echo/prompts/slow commands.
# Secrets live here so scripts, cron jobs, and Claude Code hooks can see them.

# GitLab — set GITLAB_HOST to your self-hosted instance, or leave unset for gitlab.com
export GITLAB_HOST="gitlab.example.com"
export GITLAB_TOKEN="glpat-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
export GITHUB_TOKEN="ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

# Harvest — https://id.getharvest.com/developers
export HARVEST_ACCOUNT_ID="000000"
export HARVEST_TOKEN="XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
