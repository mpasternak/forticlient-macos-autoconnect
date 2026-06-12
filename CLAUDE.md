# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A CLI workaround for FortiClient VPN on macOS, which ships no command-line interface. AppleScripts drive the FortiClient GUI via System Events accessibility APIs: `forti.scpt` selects a VPN profile, fills credentials from the macOS login Keychain, clicks Connect, polls until the tunnel is up, then hides the window and posts a notification; `forti-disconnect.scpt` does the reverse.

There is no build system or package manager — just the scripts, README.md (short, user-facing) and MANUAL.md (technical reference). There *are* lint gates: a GitHub Actions CI pipeline (osacompile syntax check of both AppleScripts on macOS, shellcheck of `forti-debug.scpt` and `tests/*.sh` on Ubuntu) and pre-commit hooks (whitespace/EOF/yaml checks plus the same shellcheck). Testing is **manual and attended**: `tests/manual-test.sh` is an interactive suite that drives the real GUI and real VPN tunnels — CI cannot run it (only its `--safe-only` subset is GUI-free); never invoke the GUI tests autonomously, they drop the user's active VPN.

## Commands

```bash
# Connect to a profile (optionally overriding the Keychain username)
osascript forti.scpt <ProfileName> [username]

# Disconnect the active tunnel
osascript forti-disconnect.scpt

# Syntax-check the AppleScripts without running them (CI does this for both)
osacompile -o /tmp/check.scpt forti.scpt
osacompile -o /tmp/check2.scpt forti-disconnect.scpt

# Run all lint checks that CI and pre-commit enforce
pre-commit run --all-files

# Test suite: GUI-free checks (safe anywhere) / full interactive run (user only)
tests/manual-test.sh --safe-only
tests/manual-test.sh

# Diagnostic dump of the FortiClient UI tree, tunnel interfaces, and Keychain entries
bash forti-debug.scpt

# Verify the tunnel independently of the GUI
ifconfig | grep -E "^(utun|ipsec)"
```

Safe partial tests without touching the GUI: `osascript forti.scpt` (usage error, exit 1) and `osascript forti.scpt NoSuchProfile` (Keychain error, exit 1) — both fail before FortiClient is activated.

Full manual testing requires FortiClient installed with profiles already configured in its GUI, Accessibility permission granted to the terminal, and a Keychain item per profile (service `forti-vpn-<ProfileName>`, account = username, password = password; case-sensitive match with the FortiClient "VPN Name" dropdown).

## Exit-code contract

Both scripts exit 0 on success (including "already connected" / "not connected") and 1 on failure. `osascript` maps **every** script error to exit status 1 — distinct exit codes are impossible without abandoning the `osascript forti.scpt` invocation form, so don't try. Instead, each failure mode raises `error "message" number N` and the number lands in the stderr text (`... (N)`). The number assignments (64 usage, 2 keychain, 3 window/accessibility tree, 4 profile missing, 5 UI element missing, 6 connect/auto-disconnect timeout, 7 externally started connect finished on a different profile, 8 FortiClient not installed) are documented in each script's header and in MANUAL.md — keep all three in sync when adding failure modes.

## File naming quirk

`forti-debug.scpt` is actually a **bash** script (shebang `#!/bin/bash`) despite the `.scpt` extension; it embeds AppleScript via `osascript` heredocs. Because of the extension, shellcheck must be explicitly forced onto it: the pre-commit hook needs both `files: forti-debug\.scpt$` and `types: [file]` (overriding the hook's default `types: [shell]`, which never matches `.scpt`), and CI invokes `shellcheck --shell=bash` on it by name. Don't "simplify" either config — the hook silently stops running.

## How the automation works (key constraints)

- FortiClient 7.x renders its UI in an embedded Chromium web view whose accessibility tree is hidden by default. The scripts enable it at runtime by setting the `AXManualAccessibility` attribute on the process — this **resets on every app restart**, so it must run on every invocation, followed by a `delay` for the tree to populate.
- UI elements are located with a recursive `entire contents of window 1` search matched by role + name (`AXPopUpButton`/"VPN Name", `AXTextField`/"Username"/"Password", `AXButton`/"Connect"/"Disconnect"). This is deliberate: the web view's group hierarchy is deeply nested and changes between FortiClient versions, so never address elements by positional path.
- The web view may re-render after the profile switch, so `entire contents` is re-fetched before filling the credential fields.
- The "VPN Name" dropdown is opened **only when its current value differs** from the requested profile — clicking the currently-selected menu item fails in the web view (field-observed as a spurious error 4), so don't "simplify" the skip away.
- Profile selection in the open dropdown is **multi-strategy with value verification**: `menu item … of menu 1` → bare `menu item …` → typed-prefix (`keystroke` + Enter), each allowed to fail silently; success means the popup's `value` re-reads as the requested profile. `click menu item` throwing is normal (field-observed even for items visibly present in the menu) — never treat the click itself as the success signal.
- Connection state is detected by polling (15 × 2 s) for the **Disconnect button plus the `Duration` static text**. The Disconnect button alone means only "connecting" (it doubles as a cancel during that phase — field-observed); the status labels (`Duration`/`Bytes Received`/`Bytes Sent`) appear only in the truly connected view. Never use the Disconnect button alone as the success signal.
- In the **connected** view the form (popup, text fields) does not exist at all; the active profile is the static text that follows the `"VPN Name"` label static text in `entire contents` document order (`activeProfileName` handler). This order-anchored lookup is the deliberate exception to "no positional addressing" — it anchors on a named label, not on group indices.
- When a **different** profile is fully connected at start, `forti.scpt` disconnects automatically (clicks Disconnect, polls for the Connect button to come back) and proceeds with the normal connect flow. Error 7 fires only when an *in-flight* attempt (started outside the script) completes on a different profile — the script never cancels an in-flight attempt.
- Element-not-found errors inside the search loops are intentionally swallowed with bare `try` blocks — the loops probe many elements that lack a `name`; actual failures are detected with found-flags after each loop and raised as numbered errors.
- In `forti.scpt`, the Keychain lookup happens **before** the GUI is touched so a missing item fails fast; the password (`-w`) is fetched first because the username's awk pipeline masks a failing `security` (the pipeline exits with awk's status).
- On a cold launch the FortiClient window can take seconds to appear, so `forti.scpt` polls for it (20 × 0.5 s, error 3 on timeout) instead of using a blind delay — keep this loop; don't replace it with a fixed `delay`.
- Hard-coded `delay` values throughout are timing-dependent workarounds, not arbitrary; MANUAL.md's debugging table documents which ones to increase for which failure mode.

## Docs maintenance

README.md is deliberately short and non-technical — keep it that way; technical detail belongs in MANUAL.md. MANUAL.md's debugging table (symptom → cause/fix) is the project's institutional knowledge about FortiClient's accessibility quirks. When changing element-lookup logic, delays, or error numbers, keep the script headers, MANUAL.md's exit-code tables, and that debugging table in sync.
