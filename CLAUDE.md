# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A CLI workaround for FortiClient VPN on macOS, which ships no command-line interface. AppleScripts drive the FortiClient GUI via System Events accessibility APIs: `forti.scpt` selects a VPN profile, fills credentials from the macOS login Keychain, clicks Connect, polls until the tunnel is up, then hides the window and posts a notification; `forti-disconnect.scpt` does the reverse.

There is no build system, package manager, or test suite — just the scripts, README.md (short, user-facing) and MANUAL.md (technical reference).

## Commands

```bash
# Connect to a profile (optionally overriding the Keychain username)
osascript forti.scpt <ProfileName> [username]

# Disconnect the active tunnel
osascript forti-disconnect.scpt

# Syntax-check a script without running it
osacompile -o /tmp/check.scpt forti.scpt

# Diagnostic dump of the FortiClient UI tree, tunnel interfaces, and Keychain entries
bash forti-debug.scpt

# Verify the tunnel independently of the GUI
ifconfig | grep -E "^(utun|ipsec)"
```

Safe partial tests without touching the GUI: `osascript forti.scpt` (usage error, exit 1) and `osascript forti.scpt NoSuchProfile` (Keychain error, exit 1) — both fail before FortiClient is activated.

Full manual testing requires FortiClient installed with profiles already configured in its GUI, Accessibility permission granted to the terminal, and a Keychain item per profile (service `forti-vpn-<ProfileName>`, account = username, password = password; case-sensitive match with the FortiClient "VPN Name" dropdown).

## Exit-code contract

Both scripts exit 0 on success (including "already connected" / "not connected") and 1 on failure. `osascript` maps **every** script error to exit status 1 — distinct exit codes are impossible without abandoning the `osascript forti.scpt` invocation form, so don't try. Instead, each failure mode raises `error "message" number N` and the number lands in the stderr text (`... (N)`). The number assignments (64 usage, 2 keychain, 3 window/accessibility tree, 4 profile missing, 5 UI element missing, 6 timeout, 7 different profile connected, 8 FortiClient not installed) are documented in each script's header and in MANUAL.md — keep all three in sync when adding failure modes.

## File naming quirk

`forti-debug.scpt` is actually a **bash** script (shebang `#!/bin/bash`) despite the `.scpt` extension; it embeds AppleScript via `osascript` heredocs.

## How the automation works (key constraints)

- FortiClient 7.x renders its UI in an embedded Chromium web view whose accessibility tree is hidden by default. The scripts enable it at runtime by setting the `AXManualAccessibility` attribute on the process — this **resets on every app restart**, so it must run on every invocation, followed by a `delay` for the tree to populate.
- UI elements are located with a recursive `entire contents of window 1` search matched by role + name (`AXPopUpButton`/"VPN Name", `AXTextField`/"Username"/"Password", `AXButton`/"Connect"/"Disconnect"). This is deliberate: the web view's group hierarchy is deeply nested and changes between FortiClient versions, so never address elements by positional path.
- The web view may re-render after the profile switch, so `entire contents` is re-fetched before filling the credential fields.
- Connection state changes are detected by polling (15 × 2 s) for the Connect/Disconnect button flip. Element-not-found errors inside the search loops are intentionally swallowed with bare `try` blocks — the loops probe many elements that lack a `name`; actual failures are detected with found-flags after each loop and raised as numbered errors.
- In `forti.scpt`, the Keychain lookup happens **before** the GUI is touched so a missing item fails fast; the password (`-w`) is fetched first because the username's awk pipeline masks a failing `security` (the pipeline exits with awk's status).
- Hard-coded `delay` values throughout are timing-dependent workarounds, not arbitrary; MANUAL.md's debugging table documents which ones to increase for which failure mode.

## Docs maintenance

README.md is deliberately short and non-technical — keep it that way; technical detail belongs in MANUAL.md. MANUAL.md's debugging table (symptom → cause/fix) is the project's institutional knowledge about FortiClient's accessibility quirks. When changing element-lookup logic, delays, or error numbers, keep the script headers, MANUAL.md's exit-code tables, and that debugging table in sync.
