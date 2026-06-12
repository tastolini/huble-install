#!/bin/bash
# Huble platform installer - sets up everything a team member needs:
#   Obsidian, Node, GitHub access, the Huble platform, the Claude agent CLI,
#   and a client vault with the Atlas plugin preconfigured for your role.
#
# Usage (one line, run it again any time to update):
#   curl -fsSL https://raw.githubusercontent.com/tastolini/huble-install/main/install.sh | bash
#
# Vaults are created in the folder you run the installer from (any drive);
# tooling hides in ~/.huble.
#
# Non-interactive overrides (mostly for testing):
#   HUBLE_HOME=~/.huble           hidden tooling root (platform/node/npm/gh)
#   HUBLE_VAULTS_DIR=/path        where vaults go (default: the launch folder)
#   HUBLE_PLATFORM_REPO=tastolini/huble-platform
#   HUBLE_ROLE=cx|copy|seo|design|dev|all   skip the role prompt
#   HUBLE_VAULT_MODE=new|clone|skip
#   HUBLE_CLIENT_NAME="Client"    with HUBLE_VAULT_MODE=new
#   HUBLE_VAULT_REPO=owner/repo   with HUBLE_VAULT_MODE=clone
#   HUBLE_NO_OPEN=1               don't open Obsidian at the end
set -euo pipefail

# Tooling lives hidden in ~/.huble (platform checkout, user-level node/npm/gh).
HUBLE_HOME="${HUBLE_HOME:-$HOME/.huble}"

# One-time migration from the old visible ~/Huble layout: move the tooling
# dirs into ~/.huble, repoint vault pipelineRoot configs and the .zprofile
# PATH block, and leave ~/Huble holding only vaults (delete it when empty).
migrate_legacy_home() {
  local old="$HOME/Huble"
  [ "$HUBLE_HOME" = "$HOME/.huble" ] || return 0
  # Config rewrites run UNCONDITIONALLY - a stale npm prefix or PATH block can
  # outlive the old folder (and a stale prefix resurrects it on any npm -g).
  if [ -f "$HOME/.npmrc" ] && grep -qs "$old" "$HOME/.npmrc"; then
    sed -i '' "s|$old/|$HUBLE_HOME/|g" "$HOME/.npmrc" 2>/dev/null || true
    printf '  - Repointed npm prefix in ~/.npmrc\n'
  fi
  if [ -f "$HOME/.zprofile" ] && grep -qs "$old" "$HOME/.zprofile"; then
    sed -i '' "s|$old/|$HUBLE_HOME/|g" "$HOME/.zprofile" 2>/dev/null || true
    printf '  - Repointed PATH block in ~/.zprofile\n'
  fi
  [ -d "$old" ] || return 0
  # Tooling dirs found under the old layout move over (idempotent - also
  # catches stragglers like an npm-global recreated by a stale .npmrc).
  local moved=false
  mkdir -p "$HUBLE_HOME"
  for d in platform node npm-global bin; do
    if [ -e "$old/$d" ] && [ ! -e "$HUBLE_HOME/$d" ]; then
      $moved || printf '  - Migrating tooling from %s to %s...\n' "$old" "$HUBLE_HOME"
      moved=true
      mv "$old/$d" "$HUBLE_HOME/$d"
    fi
  done
  # A leftover dir that exists on BOTH sides (recreated after migration) is
  # tooling debris - the hidden side wins.
  for d in npm-global bin; do
    [ -e "$old/$d" ] && [ -e "$HUBLE_HOME/$d" ] && rm -rf "$old/$d"
  done
  # Repoint pipelineRoot in any vaults still living under the old layout.
  if [ -d "$old/vaults" ] && command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs"), path = require("path");
      const [oldHome, newHome, vaultsDir] = process.argv.slice(1);
      for (const name of fs.readdirSync(vaultsDir)) {
        const cfgPath = path.join(vaultsDir, name, "project-config.json");
        if (!fs.existsSync(cfgPath)) continue;
        const raw = fs.readFileSync(cfgPath, "utf8");
        const next = raw.split(oldHome + "/platform").join(newHome + "/platform");
        if (next !== raw) { fs.writeFileSync(cfgPath, next); console.log("  - repointed", cfgPath); }
      }
    ' "$old" "$HUBLE_HOME" "$old/vaults"
  fi
  rmdir "$old" 2>/dev/null || true
}
migrate_legacy_home
PLATFORM_REPO="${HUBLE_PLATFORM_REPO:-tastolini/huble-platform}"
PLATFORM_DIR="$HUBLE_HOME/platform"
# Vaults are USER-VISIBLE work and go where the installer is launched from -
# run it from the folder (any drive) where you want client vaults to live.
LAUNCH_DIR="$(pwd)"
if [ "$LAUNCH_DIR" = "/" ] || [ ! -w "$LAUNCH_DIR" ]; then LAUNCH_DIR="$HOME"; fi
VAULTS_DIR="${HUBLE_VAULTS_DIR:-$LAUNCH_DIR}"
MIN_NODE_MAJOR=18

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m  OK %s\033[0m\n' "$*"; }
note()  { printf '  - %s\n' "$*"; }
fail()  { printf '\033[31m  X %s\033[0m\n' "$*" >&2; exit 1; }

# Reading prompts must come from the terminal even when the script itself is
# piped in via curl | bash.
ask() { # ask "Prompt" varname [default]
  local prompt="$1" var="$2" default="${3:-}" answer
  if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
  printf '%s: ' "$prompt" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=""
  if [ -z "$answer" ]; then answer="$default"; fi
  eval "$var=\"\$answer\""
}

[ "$(uname -s)" = "Darwin" ] || fail "This installer supports macOS only (for now)."
ARCH="$(uname -m)"   # arm64 or x86_64

# Non-admin users (no sudo) get user-level installs: ~/Applications for apps,
# $HUBLE_HOME/node and $HUBLE_HOME/npm-global for the toolchain. Never prompt
# for a password a user does not have.
IS_ADMIN=false
if groups 2>/dev/null | tr ' ' '\n' | grep -qx admin; then IS_ADMIN=true; fi

# Make user-level tool locations visible to this run AND future shells.
export PATH="$HUBLE_HOME/bin:$HUBLE_HOME/node/bin:$HUBLE_HOME/npm-global/bin:$PATH"
ensure_path_persisted() {
  local profile="$HOME/.zprofile" marker="# huble-installer PATH"
  if ! grep -qs "$marker" "$profile" 2>/dev/null; then
    printf '\n%s\nexport PATH="%s/bin:%s/node/bin:%s/npm-global/bin:$PATH"\n' \
      "$marker" "$HUBLE_HOME" "$HUBLE_HOME" "$HUBLE_HOME" >> "$profile"
  fi
}

bold ""
bold "Huble platform installer"
note "Tooling (hidden): $HUBLE_HOME"
note "Vaults go to: $VAULTS_DIR  (run the installer from the folder where you want them)"
mkdir -p "$HUBLE_HOME" "$VAULTS_DIR"

# ---------------------------------------------------------------- Xcode CLT / git
step "Checking developer tools (git)"
if xcode-select -p >/dev/null 2>&1; then
  ok "Command Line Tools present"
else
  note "Triggering the macOS Command Line Tools install dialog - click Install, then re-run this script."
  xcode-select --install >/dev/null 2>&1 || true
  fail "Re-run the installer once the Command Line Tools have finished installing."
fi

# ---------------------------------------------------------------- Obsidian
step "Checking Obsidian"
if [ -d "/Applications/Obsidian.app" ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
  ok "Obsidian installed"
else
  note "Downloading the latest Obsidian..."
  # Take the .dmg asset URL straight from the release metadata - asset naming
  # has changed before (no more -universal suffix), so never construct it.
  OBS_URL="$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | sed -n 's/.*"browser_download_url": *"\([^"]*\.dmg\)".*/\1/p' | head -1)"
  [ -n "$OBS_URL" ] || fail "Could not find the Obsidian .dmg download URL."
  OBS_DMG="/tmp/Obsidian-latest.dmg"
  curl -fL --progress-bar -o "$OBS_DMG" "$OBS_URL"
  # Admins install system-wide; everyone else gets ~/Applications (works the
  # same, no password needed).
  if $IS_ADMIN || [ -w /Applications ]; then APP_DIR="/Applications"; else APP_DIR="$HOME/Applications"; fi
  mkdir -p "$APP_DIR"
  note "Installing to $APP_DIR..."
  MOUNT_DIR="$(hdiutil attach "$OBS_DMG" -nobrowse -readonly | sed -n 's/.*\(\/Volumes\/.*\)/\1/p' | tail -1)"
  if ! cp -R "$MOUNT_DIR/Obsidian.app" "$APP_DIR/" 2>/dev/null; then
    if $IS_ADMIN; then
      note "Needs your password to write to $APP_DIR..."
      sudo cp -R "$MOUNT_DIR/Obsidian.app" "$APP_DIR/"
    else
      hdiutil detach "$MOUNT_DIR" -quiet || true
      fail "Could not write to $APP_DIR."
    fi
  fi
  hdiutil detach "$MOUNT_DIR" -quiet
  rm -f "$OBS_DMG"
  ok "Obsidian installed in $APP_DIR"
fi

# ---------------------------------------------------------------- Node
step "Checking Node.js (>= $MIN_NODE_MAJOR)"
node_ok=false
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$NODE_MAJOR" -ge "$MIN_NODE_MAJOR" ]; then node_ok=true; fi
fi
if $node_ok; then
  ok "Node $(node --version)"
else
  case "$ARCH" in
    arm64) NODE_ARCH="arm64" ;;
    *)     NODE_ARCH="x64" ;;
  esac
  if command -v brew >/dev/null 2>&1; then
    note "Installing Node via Homebrew..."
    brew install node >/dev/null
  else
    # Official tarball into $HUBLE_HOME/node — works with or without admin
    # rights, no password, and keeps tooling hidden like everything else.
    # (The old admin path downloaded node-<ver>-<arch>.pkg, which does not
    # exist on nodejs.org — the macOS pkg is universal, no arch suffix — so
    # every brew-less admin machine 404'd and aborted here.)
    NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | sed -n 's/.*"version": *"\(v22[^"]*\)".*/\1/p' | head -1)"
    if [ -z "$NODE_VER" ]; then
      fail "Could not determine the latest Node 22 version from nodejs.org (network/proxy issue?). Install Node 18+ manually (https://nodejs.org) and re-run this installer."
    fi
    note "Installing Node $NODE_VER into $HUBLE_HOME/node (no password needed)..."
    NODE_TAR="/tmp/node-$NODE_VER.tar.gz"
    curl -fL --progress-bar -o "$NODE_TAR" "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-darwin-$NODE_ARCH.tar.gz"
    rm -rf "$HUBLE_HOME/node"
    mkdir -p "$HUBLE_HOME/node"
    tar -xzf "$NODE_TAR" -C "$HUBLE_HOME/node" --strip-components 1
    rm -f "$NODE_TAR"
    ensure_path_persisted
  fi
  ok "Node $(node --version) installed"
fi

# ---------------------------------------------------------------- GitHub CLI + auth
step "Checking GitHub access"
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    note "Installing GitHub CLI via Homebrew..."
    brew install gh >/dev/null
  else
    note "Installing GitHub CLI..."
    GH_TAG="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    GH_VER="${GH_TAG#v}"
    case "$ARCH" in
      arm64) GH_ARCH="macOS_arm64" ;;
      *)     GH_ARCH="macOS_amd64" ;;
    esac
    GH_ZIP="/tmp/gh.zip"
    curl -fL --progress-bar -o "$GH_ZIP" \
      "https://github.com/cli/cli/releases/download/$GH_TAG/gh_${GH_VER}_${GH_ARCH}.zip"
    mkdir -p "$HUBLE_HOME/bin"
    ditto -xk "$GH_ZIP" /tmp/gh-extract
    cp "/tmp/gh-extract/gh_${GH_VER}_${GH_ARCH}/bin/gh" "$HUBLE_HOME/bin/gh"
    chmod +x "$HUBLE_HOME/bin/gh"
    rm -rf "$GH_ZIP" /tmp/gh-extract
    ensure_path_persisted
  fi
fi
ok "GitHub CLI present"
if gh auth status >/dev/null 2>&1; then
  ok "GitHub authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
  note "Sign in to GitHub - a browser window will guide you (device code flow)."
  gh auth login --hostname github.com --git-protocol https --web < /dev/tty
fi

# ---------------------------------------------------------------- Platform repo
step "Installing the Huble platform"
if [ -d "$PLATFORM_DIR/.git" ]; then
  note "Updating existing platform checkout..."
  git -C "$PLATFORM_DIR" pull --ff-only || note "Pull failed (local changes?) - keeping current version."
  # Older installs sparse-checked plugins/ too; narrow them to the pipeline.
  if [ -f "$PLATFORM_DIR/.git/info/sparse-checkout" ]; then
    git -C "$PLATFORM_DIR" sparse-checkout set --cone huble-pipeline 2>/dev/null || true
  fi
else
  # Team machines need the pipeline only - it carries the committed plugin
  # dist (huble-pipeline/dist/atlas-cx) that cx init installs from. No plugin
  # sources, no client vaults, no planning docs.
  gh repo clone "$PLATFORM_REPO" "$PLATFORM_DIR" -- --depth 1 --sparse
  git -C "$PLATFORM_DIR" sparse-checkout set --cone huble-pipeline
fi
HUBLE="$PLATFORM_DIR/huble-pipeline/bin/huble"
[ -x "$HUBLE" ] || chmod +x "$HUBLE" 2>/dev/null || true
[ -f "$HUBLE" ] || fail "Platform clone incomplete: $HUBLE not found."
ok "Platform at $PLATFORM_DIR"

# ---------------------------------------------------------------- Claude Code CLI
step "Checking Claude Code (agent CLI)"
if command -v claude >/dev/null 2>&1; then
  ok "Claude Code $(claude --version 2>/dev/null | head -1 || true)"
else
  note "Installing Claude Code..."
  if ! npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; then
    if $IS_ADMIN; then
      sudo npm install -g @anthropic-ai/claude-code >/dev/null
    else
      # npm's global prefix is not writable: use a user-level prefix instead.
      npm config set prefix "$HUBLE_HOME/npm-global"
      npm install -g @anthropic-ai/claude-code >/dev/null
      ensure_path_persisted
    fi
  fi
  ok "Claude Code installed"
  note "After this installer finishes, run:  claude login"
fi

# ---------------------------------------------------------------- Client vault
step "Setting up a client vault"
VAULT_MODE="${HUBLE_VAULT_MODE:-}"
if [ -z "$VAULT_MODE" ]; then
  printf '  How do you want to start?\n' > /dev/tty
  printf '    1) Clone an existing client vault from GitHub\n' > /dev/tty
  printf '    2) Create a new client vault\n' > /dev/tty
  printf '    3) Skip - I already have my vault\n' > /dev/tty
  ask "  Choose 1/2/3" choice "3"
  case "$choice" in
    1) VAULT_MODE="clone" ;;
    2) VAULT_MODE="new" ;;
    *) VAULT_MODE="skip" ;;
  esac
fi

VAULT_PATH=""
case "$VAULT_MODE" in
  clone)
    REPO="${HUBLE_VAULT_REPO:-}"
    if [ -z "$REPO" ]; then ask "  Vault repo (owner/name)" REPO; fi
    VAULT_PATH="$VAULTS_DIR/$(basename "$REPO")"
    if [ -d "$VAULT_PATH/.git" ]; then
      git -C "$VAULT_PATH" pull --ff-only || true
    else
      gh repo clone "$REPO" "$VAULT_PATH"
    fi
    ;;
  new)
    CLIENT="${HUBLE_CLIENT_NAME:-}"
    if [ -z "$CLIENT" ]; then ask "  Client name" CLIENT; fi
    [ -n "$CLIENT" ] || fail "Client name required."
    VAULT_PATH="$VAULTS_DIR/$CLIENT"
    "$HUBLE" vault init --client "$CLIENT" --vault "$VAULT_PATH"
    ;;
  skip)
    note "Skipping vault setup."
    ;;
esac

# ---------------------------------------------------------------- Role + plugin
if [ -n "$VAULT_PATH" ]; then
  ROLE="${HUBLE_ROLE:-}"
  if [ -z "$ROLE" ]; then
    note "cx/copy/seo also set the Atlas Inspector role; design/dev install only"
    note "that stage's tooling and check out only its slice of the vault; all = admin."
    ask "  Your role (cx / copy / seo / design / dev / all)" ROLE "cx"
  fi
  step "Installing the Atlas plugin (role: $ROLE)"
  "$HUBLE" cx init --vault "$VAULT_PATH" --role "$ROLE"
  ok "Atlas plugin installed and enabled, role set to $ROLE"
fi

# ---------------------------------------------------------------- Done
step "Done"
if [ -n "$VAULT_PATH" ]; then
  note "Vault: $VAULT_PATH"
  if [ -z "${HUBLE_NO_OPEN:-}" ]; then
    # Obsidian reads obsidian.json only at startup and REWRITES it from memory
    # on quit - registering while it runs gets ignored and then overwritten.
    # Quit it first, register, then relaunch.
    if pgrep -xq Obsidian; then
      note "Quitting Obsidian to register the vault..."
      osascript -e 'tell application "Obsidian" to quit' >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -xq Obsidian || break
        sleep 1
      done
    fi
    note "Registering the vault with Obsidian..."
    # Same record Obsidian writes when you pick "Open folder as vault".
    node -e '
      const fs = require("fs"), path = require("path"), os = require("os");
      const cfgDir = path.join(os.homedir(), "Library/Application Support/obsidian");
      const cfgPath = path.join(cfgDir, "obsidian.json");
      fs.mkdirSync(cfgDir, { recursive: true });
      let cfg = {};
      try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch {}
      cfg.vaults = cfg.vaults || {};
      const vaultPath = process.argv[1];
      if (!Object.values(cfg.vaults).some(v => v.path === vaultPath)) {
        const id = Array.from({length: 16}, () => "0123456789abcdef"[Math.floor(Math.random()*16)]).join("");
        for (const v of Object.values(cfg.vaults)) delete v.open;
        cfg.vaults[id] = { path: vaultPath, ts: Date.now(), open: true };
        fs.writeFileSync(cfgPath, JSON.stringify(cfg));
      }
      process.stdout.write(encodeURIComponent(vaultPath));
    ' "$VAULT_PATH" > /tmp/huble-vault-url.txt
    ENCODED_PATH="$(cat /tmp/huble-vault-url.txt)"
    rm -f /tmp/huble-vault-url.txt
    note "Opening the vault in Obsidian..."
    open "obsidian://open?path=$ENCODED_PATH" 2>/dev/null \
      || open -a Obsidian 2>/dev/null \
      || open "$HOME/Applications/Obsidian.app" 2>/dev/null || true
    note "Obsidian will ask you to trust the vault, then enable the Atlas plugin under Community plugins if prompted."
    note "If the vault does not open: in Obsidian's vault picker choose 'Open folder as vault' and select $VAULT_PATH"
  fi
fi
note "Platform: $PLATFORM_DIR  (re-run this installer any time to update everything)"
if ! command -v claude >/dev/null 2>&1 || ! [ -e "$HOME/.claude" ]; then
  note "Remember to authenticate the agent CLI once:  claude login"
fi
bold ""
