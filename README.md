# Huble installer

One-line setup for the Huble platform on a Mac. It checks and installs
everything a team member needs — Obsidian, Node.js, GitHub access, the Huble
platform, the Claude agent CLI — then clones or creates a client vault with
the Atlas plugin preconfigured for your role (CX / Copy / SEO — each machine gets only its stage's tooling and a sparse checkout of just its slice of the vault).

It also offers to install Homebrew + poppler (optional, consent-based —
Homebrew's installer asks for your macOS password once): agents use poppler's
`pdftoppm` to view PDF pages as images (brand guides, sitemap diagrams). If
you decline or the install fails, everything else still works — agents fall
back to extracted text, and you can add it later with `brew install poppler`.

```bash
curl -fsSL https://raw.githubusercontent.com/tastolini/huble-install/main/install.sh | bash
```

Run it **from the folder where you want your client vaults** — secondary
drive, `~/Work/Clients`, anywhere. Vaults are created there; all tooling
(platform, node, CLIs) stays hidden in `~/.huble`.

Safe to re-run any time: it updates the platform and the plugin in lockstep
and never touches your per-machine settings (role, agent preferences, API
keys are merged, not overwritten).

You'll be asked to sign in to GitHub in the browser the first time (the
platform and client vaults are private repositories). After installing, run
`claude login` once to authenticate the agent CLI with your Claude plan.

## Publishing a review site (strategy roles)

A `cx` / `copy` / `seo` machine has a **sparse** checkout — only its slice of
the vault. To publish the client review site (strategy doc + canvases):

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
