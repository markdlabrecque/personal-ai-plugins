#!/usr/bin/env bash
# Ensures the dependencies the youtube-playlist-url MCP needs are installed:
#   - Homebrew (only prompted; the official installer requires interaction)
#   - yt-dlp (installed via brew if missing and the user agrees)
#   - node_modules under this directory (npm install)
#
# Safe to re-run. Exits 0 when everything is in place, non-zero otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  # confirm "prompt" [default]   default = Y|N (case-insensitive), defaults to N
  local prompt="$1"
  local default="${2:-N}"
  local hint reply
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$prompt $hint " reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Homebrew ---
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew is not installed."
  cat >&2 <<'EOF'

The official installer will:
  - prompt for your sudo password
  - require you to accept the Xcode Command Line Tools license
  - modify your shell profile to add brew to PATH
EOF
  if confirm "Run the Homebrew installer now?" Y; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # The installer prints PATH-setup hints; pick them up for the current shell.
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    command -v brew >/dev/null 2>&1 || fail "Homebrew install did not complete. Open a new shell and re-run this script."
  else
    fail "Homebrew is required. Install manually:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  fi
fi
say "Homebrew detected: $(brew --version | head -1)"

# --- yt-dlp ---
if ! command -v yt-dlp >/dev/null 2>&1; then
  warn "yt-dlp not found."
  if confirm "Install yt-dlp via 'brew install yt-dlp'?" Y; then
    brew install yt-dlp
  else
    fail "yt-dlp is required. Install with: brew install yt-dlp"
  fi
else
  say "yt-dlp detected: $(yt-dlp --version)"
fi

# --- node_modules ---
if [[ ! -d "$HERE/node_modules" ]]; then
  say "Installing MCP server dependencies..."
  (cd "$HERE" && npm install --silent)
else
  say "node_modules already present."
fi

say "Setup complete. Restart Claude Code to load the MCP."
