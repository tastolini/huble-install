# Huble installer

One-line setup for the Huble platform on a Mac. It checks and installs
everything a team member needs — Obsidian, Node.js, GitHub access, the Huble
platform, the Claude agent CLI — then clones or creates a client vault with
the Atlas plugin preconfigured for your role (CX / Copy / SEO).

```bash
curl -fsSL https://raw.githubusercontent.com/tastolini/huble-install/main/install.sh | bash
```

Safe to re-run any time: it updates the platform and the plugin in lockstep
and never touches your per-machine settings (role, agent preferences, API
keys are merged, not overwritten).

You'll be asked to sign in to GitHub in the browser the first time (the
platform and client vaults are private repositories). After installing, run
`claude login` once to authenticate the agent CLI with your Claude plan.

This repository contains no secrets — only the bootstrap logic. The platform
itself lives in a private repo that the installer clones after you sign in.
