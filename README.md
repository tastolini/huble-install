# Huble installer

One-line setup for the Huble platform on a Mac. It checks and installs
everything a team member needs — Obsidian, Node.js (24+), GitHub access, the
Huble platform, the Claude agent CLI, the dex task CLI — then clones or
creates a client vault with the Atlas plugin preconfigured for your role
(CX / Copy / SEO / Design / Dev — each machine gets only its stage's tooling
and a sparse checkout of just its slice of the vault).

As its **last** step — after your vault is fully set up — it also offers to
install Homebrew + poppler (optional, consent-based — Homebrew's installer
asks for your macOS password once): agents use poppler's `pdftoppm` to view
PDF pages as images (brand guides, sitemap diagrams). If you decline or the
install fails, everything else still works — agents fall back to extracted
text, and you can add it later with `brew install poppler`.

Homebrew is never **required**: the installer's own toolchain (Node, the
GitHub CLI, npm packages) installs without it, and Homebrew is only offered
for poppler. If brew is already on the machine, the installer uses it where
it helps.

```bash
curl -fsSL https://raw.githubusercontent.com/tastolini/huble-install/main/install.sh | bash
```

Run it **from the folder where you want your client vaults** — secondary
drive, `~/Work/Clients`, anywhere. Vaults are created there; all tooling
(platform, node, CLIs) stays hidden in `~/.huble`.

The installer puts the `huble` command on your PATH (it appends one block to
`~/.zprofile`), so `huble ...` works in any **new** terminal after installing.

Safe to re-run any time — re-running **is** the update path: it pulls the
latest platform, and when you skip vault creation it offers to re-init your
existing vault (`huble cx init`) so the plugin, skills and commands update in
lockstep with the platform. Decline and only the platform updates. It never
touches your per-machine settings (role, agent preferences, API keys are
merged, not overwritten).

You'll be asked to sign in to GitHub in the browser the first time (the
platform and client vaults are private repositories). After installing, run
`claude login` once to authenticate the agent CLI with your Claude plan.

## Publishing a review site (strategy roles)

A `cx` / `copy` / `seo` machine has a **sparse** checkout — only its slice of
the vault. The `huble` command is on your PATH after installing (open a new
terminal if it isn't found in the one you installed from). To publish the
client review site (strategy doc + canvases):

1. Put your here.now API key in `~/.herenow/credentials` (one line), or export
   `HERENOW_API_KEY`. Without it, publishing fails.
2. From the vault:

   ```bash
   huble site assemble --vault .
   huble site publish --vault . --force
   ```

   `--force` is required because a strategy machine is sparse — without the
   design/prototype surfaces the publisher refuses by default (so it can't wipe
   surfaces it can't see). The first publish mints the here.now slug and locks
   it into `project-config.json`; later publishes reuse that one site for life.

This repository contains no secrets — only the bootstrap logic. The platform
itself lives in a private repo that the installer clones after you sign in.
