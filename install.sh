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
#   HUBLE_ROLE=cx|copy|seo|design|dev        skip the role prompt
#                 (all still valid here — advanced, not shown in the menu)
#   HUBLE_VAULT_MODE=new|clone|skip
#   HUBLE_VAULT_REINIT=/path|no   with skip: re-init that vault (or don't ask)
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
MIN_NODE_MAJOR=24   # the dex task CLI (@zeeg/dex) requires Node >= 24

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m  OK %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m  ! %s\033[0m\n' "$*"; }
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

ask_role() { # ask_role varname - prompt until one of the five menu roles
  local r
  while :; do
    ask "  Your role (cx / copy / seo / design / dev)" r "cx"
    case "$r" in
      cx|copy|seo|design|dev) break ;;
      *) warn "Unknown role '$r' - choose one of: cx / copy / seo / design / dev" ;;
    esac
  done
  eval "$1=\"\$r\""
}

# Tiny JSON helpers for machine.json files (~/.huble remembers the last vault;
# a vault's .huble remembers its role). Only called after the Node step.
json_read() { # json_read file key -> stdout (empty if absent/unreadable)
  node -e '
    try {
      const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]];
      if (typeof v === "string") process.stdout.write(v);
    } catch {}
  ' "$1" "$2" 2>/dev/null || true
}
json_write() { # json_write file key value - merge one key, keep the rest
  node -e '
    const fs = require("fs"), path = require("path");
    const [file, key, value] = process.argv.slice(1);
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
    cfg[key] = value;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  ' "$1" "$2" "$3"
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
  # ~/.zprofile is the primary (macOS ships zsh). ~/.bash_profile is appended
  # only when it already exists - creating one would change bash's startup
  # file resolution (~/.bash_profile shadows ~/.profile).
  local marker="# huble-installer PATH" profile
  for profile in "$HOME/.zprofile" "$HOME/.bash_profile"; do
    if [ "$profile" = "$HOME/.bash_profile" ] && [ ! -f "$profile" ]; then continue; fi
    if ! grep -qs "$marker" "$profile" 2>/dev/null; then
      printf '\n%s\nexport PATH="%s/bin:%s/node/bin:%s/npm-global/bin:$PATH"\n' \
        "$marker" "$HUBLE_HOME" "$HUBLE_HOME" "$HUBLE_HOME" >> "$profile"
    fi
  done
}

bold ""
bold "Huble platform installer"
note "Tooling (hidden): $HUBLE_HOME"
note "Vaults go to: $VAULTS_DIR  (run the installer from the folder where you want them)"
mkdir -p "$HUBLE_HOME" "$VAULTS_DIR"
# Persist the PATH block unconditionally - brew-based installs never hit the
# fallback branches that used to be the only callers, so `huble` (and any
# user-level tooling) was missing from new terminals on those machines.
ensure_path_persisted

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
  if [ "$NODE_MAJOR" -ge "$MIN_NODE_MAJOR" ]; then
    node_ok=true
  else
    note "Node $(node --version) is too old - the dex CLI needs Node >= $MIN_NODE_MAJOR. Upgrading..."
  fi
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
    # An outdated brew node makes `brew install` error out with an "already
    # installed, run brew upgrade" hint - follow that hint automatically.
    brew install node >/dev/null 2>&1 || brew upgrade node >/dev/null
  else
    # Official tarball into $HUBLE_HOME/node — works with or without admin
    # rights, no password, and keeps tooling hidden like everything else.
    # (The old admin path downloaded node-<ver>-<arch>.pkg, which does not
    # exist on nodejs.org — the macOS pkg is universal, no arch suffix — so
    # every brew-less admin machine 404'd and aborted here.)
    NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | sed -n 's/.*"version": *"\(v24[^"]*\)".*/\1/p' | head -1)"
    if [ -z "$NODE_VER" ]; then
      fail "Could not determine the latest Node 24 version from nodejs.org (network/proxy issue?). Install Node $MIN_NODE_MAJOR+ manually (https://nodejs.org) and re-run this installer."
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
  # An older node earlier in PATH (e.g. a pinned node@18 keg) can shadow the
  # fresh install - verify what actually resolves before moving on.
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$NODE_MAJOR" -lt "$MIN_NODE_MAJOR" ]; then
    fail "Node $(node --version 2>/dev/null || echo '?') still resolves after the install - an older Node earlier in your PATH is shadowing it. The dex CLI needs Node >= $MIN_NODE_MAJOR: remove or upgrade the old Node (https://nodejs.org) and re-run this installer."
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
# Bare `huble` must work in any terminal - the README and the pipeline's own
# output tell users to run it unprefixed, so link it into the PATH dir the
# installer persists above.
mkdir -p "$HUBLE_HOME/bin"
ln -sf "$HUBLE" "$HUBLE_HOME/bin/huble"
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

# ---------------------------------------------------------------- dex (task tracker CLI)
step "Checking dex (task tracker CLI)"
if command -v dex >/dev/null 2>&1; then
  ok "dex $(dex --version 2>/dev/null | head -1 || true)"
else
  note "Installing dex..."
  # Same fallback chain as Claude Code above: plain npm -g, then sudo for
  # admins, then a user-level npm prefix for everyone else.
  if ! npm install -g @zeeg/dex >/dev/null 2>&1; then
    if $IS_ADMIN; then
      sudo npm install -g @zeeg/dex >/dev/null
    else
      # npm's global prefix is not writable: use a user-level prefix instead.
      npm config set prefix "$HUBLE_HOME/npm-global"
      npm install -g @zeeg/dex >/dev/null
      ensure_path_persisted
    fi
  fi
  ok "dex installed"
fi

# ---------------------------------------------------------------- Poppler (PDF page rendering)
# Agents view PDF pages as images through pdftoppm when reading a PDF (brand
# guides, sitemap diagrams — anything where the text extraction alone is not
# enough). The pipeline itself no longer needs poppler (PDF text conversion is
# bundled), so this is agent tooling only: EVERY failure path below is
# non-fatal — decline, curl failure, brew failure all warn and continue.
step "Checking PDF page rendering (poppler)"
poppler_unavailable() {
  warn "PDF page rendering unavailable (agents will fall back to text sources); install later with: brew install poppler"
}
if command -v pdftoppm >/dev/null 2>&1; then
  ok "poppler (pdftoppm)"
else
  if ! command -v brew >/dev/null 2>&1; then
    if $IS_ADMIN; then
      note "poppler installs via Homebrew, which is not on this Mac yet."
      note "Why: agents render PDF pages as images with it - without it they can"
      note "only read a PDF's extracted text (diagram-heavy PDFs become unreadable)."
      note "Homebrew's official installer will ask for your macOS password once."
      ask "  Install Homebrew now? (y/N)" INSTALL_BREW "n"
      case "$INSTALL_BREW" in
        [Yy]*)
          BREW_INSTALL_SCRIPT="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || BREW_INSTALL_SCRIPT=""
          if [ -z "$BREW_INSTALL_SCRIPT" ]; then
            warn "Could not download the Homebrew installer (network issue?)."
          elif /bin/bash -c "$BREW_INSTALL_SCRIPT" < /dev/tty; then
            # The Homebrew installer persists shellenv for future shells; make
            # brew visible to THIS run too (Apple Silicon, then Intel).
            if [ -x /opt/homebrew/bin/brew ]; then
              eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -x /usr/local/bin/brew ]; then
              eval "$(/usr/local/bin/brew shellenv)"
            fi
          else
            warn "Homebrew install failed or was cancelled."
          fi
          ;;
        *) note "Skipping Homebrew." ;;
      esac
    else
      # Homebrew's installer needs an admin account - never prompt for a
      # password this user does not have (same rule as the app installs).
      note "poppler installs via Homebrew, which needs an admin account."
    fi
  fi
  if command -v brew >/dev/null 2>&1; then
    # On shared Macs Homebrew is often installed (and owned) by another user
    # account - brew install then fails with a wall of "not writable" errors
    # and suggests a chown that would steal the other user's Homebrew.
    # Preflight the prefix instead of letting brew crash into it.
    BREW_PREFIX="$(brew --prefix 2>/dev/null)" || BREW_PREFIX=""
    [ -n "$BREW_PREFIX" ] || BREW_PREFIX="$(dirname "$(dirname "$(command -v brew)")")"
    if [ -w "$BREW_PREFIX/Cellar" ] || { [ ! -e "$BREW_PREFIX/Cellar" ] && [ -w "$BREW_PREFIX" ]; }; then
      note "Installing poppler (PDF page rendering for agents)..."
      if brew install poppler >/dev/null; then
        ok "poppler (pdftoppm) installed"
      else
        poppler_unavailable
      fi
    else
      warn "Homebrew at $BREW_PREFIX is owned by another user account on this Mac."
      warn "Ask that account to run: brew install poppler"
      poppler_unavailable
    fi
  else
    poppler_unavailable
  fi
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

# Role comes BEFORE vault setup so every install step (vault init included)
# is role-scoped from the start — no all-roles install followed by a re-filter.
ROLE="${HUBLE_ROLE:-}"
if [ "$VAULT_MODE" != "skip" ] && [ -z "$ROLE" ]; then
  note "Your role sets the Atlas Inspector tab and installs only that stage's"
  note "tooling + a sparse checkout of its slice of the vault."
  ask_role ROLE
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
    "$HUBLE" vault init --client "$CLIENT" --vault "$VAULT_PATH" --role "$ROLE"
    ;;
  skip)
    note "Skipping vault setup (no new vault created)."
    # Re-runs default to skip, which used to leave the vault's plugin/skills/
    # commands on the old version while the platform updated underneath.
    # Offer a re-init of the existing vault so both move in lockstep;
    # declining (explicit no / Enter / no tty) keeps plain skip behavior.
    REINIT_VAULT="${HUBLE_VAULT_REINIT:-}"
    if [ "$REINIT_VAULT" = "no" ]; then
      REINIT_VAULT=""
    elif [ -z "$REINIT_VAULT" ]; then
      LAST_VAULT="$(json_read "$HUBLE_HOME/machine.json" lastVault)"
      if [ -n "$LAST_VAULT" ] && [ ! -d "$LAST_VAULT" ]; then LAST_VAULT=""; fi
      if ( : < /dev/tty ) 2>/dev/null; then
        if [ -n "$LAST_VAULT" ]; then
          ask "  Update the vault at $LAST_VAULT too (plugin/skills/commands)? (Y/n)" UPDATE_VAULT "y"
          case "$UPDATE_VAULT" in [Yy]*) REINIT_VAULT="$LAST_VAULT" ;; esac
        else
          ask "  Update an existing vault's plugin/skills/commands too? (y/N)" UPDATE_VAULT "n"
          case "$UPDATE_VAULT" in
            [Yy]*) ask "  Vault path" REINIT_VAULT ;;
          esac
        fi
      fi
    fi
    if [ -n "$REINIT_VAULT" ]; then
      [ -d "$REINIT_VAULT" ] || fail "No vault folder at $REINIT_VAULT."
      # The vault remembers its role; only ask (and persist) when it doesn't.
      REINIT_ROLE="$(json_read "$REINIT_VAULT/.huble/machine.json" role)"
      if [ -z "$REINIT_ROLE" ]; then
        ask_role REINIT_ROLE
        json_write "$REINIT_VAULT/.huble/machine.json" role "$REINIT_ROLE"
      fi
      note "Updating the vault's plugin/skills/commands (role: $REINIT_ROLE)..."
      "$HUBLE" cx init --vault "$REINIT_VAULT" --role "$REINIT_ROLE"
      json_write "$HUBLE_HOME/machine.json" lastVault "$REINIT_VAULT"
      ok "Vault at $REINIT_VAULT updated in lockstep with the platform"
    fi
    ;;
esac

# ---------------------------------------------------------------- Plugin + role tooling
if [ -n "$VAULT_PATH" ]; then
  step "Installing the Atlas plugin (role: $ROLE)"
  "$HUBLE" cx init --vault "$VAULT_PATH" --role "$ROLE"
  # Remember this vault + role so a future skip-mode re-run can offer the
  # lockstep vault update without re-asking for everything.
  json_write "$HUBLE_HOME/machine.json" lastVault "$VAULT_PATH"
  json_write "$VAULT_PATH/.huble/machine.json" role "$ROLE"
  ok "Atlas plugin installed and enabled, role set to $ROLE"
fi

# ---------------------------------------------------------------- Done
step "Done"
if [ -n "$VAULT_PATH" ]; then
  note "Vault: $VAULT_PATH"
  if [ -z "${HUBLE_NO_OPEN:-}" ]; then
    # Obsidian reads obsidian.json only at startup and REWRITES it from memory
    # on quit - registering while it runs gets ignored and then overwritten.
    # Quit it first, WAIT FOR THE QUIT TO FULLY FINISH (a slow quit flushes
    # obsidian.json after the 10s mark and silently clobbers our registration
    # - seen in the field), register, relaunch, then VERIFY the entry survived.
    if pgrep -xq Obsidian; then
      note "Quitting Obsidian to register the vault..."
      osascript -e 'tell application "Obsidian" to quit' >/dev/null 2>&1 || true
      i=0
      while [ "$i" -lt 30 ]; do
        pgrep -xq Obsidian || break
        sleep 1
        i=$((i+1))
      done
      if pgrep -xq Obsidian; then
        note "Obsidian is still shutting down - skipping auto-registration."
        note "Open the vault manually: vault picker > 'Open folder as vault' > $VAULT_PATH"
      fi
      # Let the final config flush land before we write.
      sleep 2
    fi
    register_vault() {
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
      ' "$VAULT_PATH"
    }
    vault_registered() {
      node -e '
        const fs = require("fs"), path = require("path"), os = require("os");
        const cfgPath = path.join(os.homedir(), "Library/Application Support/obsidian/obsidian.json");
        let cfg = {};
        try { cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")); } catch {}
        const ok = Object.values(cfg.vaults || {}).some(v => v.path === process.argv[1]);
        process.exit(ok ? 0 : 1);
      ' "$VAULT_PATH"
    }
    note "Registering the vault with Obsidian..."
    ENCODED_PATH="$(register_vault)"
    note "Opening the vault in Obsidian..."
    open "obsidian://open?path=$ENCODED_PATH" 2>/dev/null \
      || open -a Obsidian 2>/dev/null \
      || open "$HOME/Applications/Obsidian.app" 2>/dev/null || true
    # Verify the registration survived the relaunch; a leftover quit-flush can
    # still clobber it. One silent retry, then a loud manual instruction.
    sleep 5
    if ! vault_registered; then
      note "Registration was overwritten - retrying once..."
      ENCODED_PATH="$(register_vault)"
      open "obsidian://open?path=$ENCODED_PATH" 2>/dev/null || true
      sleep 5
    fi
    if vault_registered; then
      note "Vault registered with Obsidian."
    else
      note "Could not register the vault automatically."
      note "In Obsidian: vault picker (bottom-left) > 'Open folder as vault' > $VAULT_PATH"
    fi
    note "Obsidian will ask you to trust the vault, then enable the Atlas plugin under Community plugins if prompted."
    note "If the vault does not open: in Obsidian's vault picker choose 'Open folder as vault' and select $VAULT_PATH"
  fi
fi
note "Platform: $PLATFORM_DIR  (re-run this installer any time to update everything)"
note "The huble command is on your PATH in new terminals (this shell already has it)."
if ! command -v claude >/dev/null 2>&1 || ! [ -e "$HOME/.claude" ]; then
  note "Remember to authenticate the agent CLI once:  claude login"
fi
bold ""
