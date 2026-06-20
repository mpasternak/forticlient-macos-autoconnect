# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A CLI workaround for FortiClient VPN on macOS, which ships no command-line interface. AppleScripts drive the FortiClient GUI via System Events accessibility APIs: `forti.scpt` selects a VPN profile, fills credentials from the macOS login Keychain, clicks Connect, polls until the tunnel is up, then hides the window and posts a notification; `forti-disconnect.scpt` does the reverse. `forti-status.scpt` is a read-only query — it prints the connected profile's name to stdout (exit 0) or nothing (exit 1), without launching the app, changing state, or stealing focus.

There is a **small build step** (a concatenator, no package manager): the three `.scpt` tools are generated from sources under `src/` — per-tool `on run` bodies (`src/<tool>.applescript`) plus shared handlers (`src/lib/*.applescript`) inlined via `--#include` directives by `build.sh`. The generated tools are **committed**, so users still clone and run; **edit `src/`, never the generated `.scpt`** (each carries a "GENERATED" banner). `./build.sh --check` (run by CI and pre-commit) diffs the committed tools against `src/` and fails on drift. `forti-debug.scpt` is hand-written bash and is *not* generated. README.md (short, user-facing) and MANUAL.md (technical reference) round out the docs; MANUAL.md's "Building" section is the authority on the build. Releases are cut by `release.sh`, a CalVer tagger: the git tag (`vYYYY.MM.DD`, with a `.N` micro for same-day re-releases) is the only version record — there is nothing to "bump" in a file. There *are* lint and build gates: a GitHub Actions CI pipeline (on macOS: `build.sh --check`, then osacompile syntax check of all three generated AppleScripts; on Ubuntu: shellcheck of `build.sh`, `forti-debug.scpt`, `release.sh` and `tests/*.sh`) and pre-commit hooks (whitespace/EOF/yaml checks, the same shellcheck, and a local `build.sh --check` hook). Testing is **manual and attended**: `tests/manual-test.sh` is an interactive suite that drives the real GUI and real VPN tunnels — CI cannot run it (only its `--safe-only` subset is GUI-free); never invoke the GUI tests autonomously, they drop the user's active VPN.

## Commands

```bash
# Connect to a profile (optionally overriding the Keychain username)
osascript forti.scpt <ProfileName> [username]

# Disconnect the active tunnel
osascript forti-disconnect.scpt

# Print the connected profile name (stdout, exit 0), or nothing (exit 1)
osascript forti-status.scpt

# Rebuild the .scpt tools from src/ (edit src/, never the generated *.scpt)
./build.sh
# Verify the committed tools match src/ — CI and pre-commit run this
./build.sh --check

# Syntax-check the AppleScripts without running them (CI does this for all three)
osacompile -o /tmp/check.scpt forti.scpt
osacompile -o /tmp/check2.scpt forti-disconnect.scpt
osacompile -o /tmp/check3.scpt forti-status.scpt

# Run all lint checks that CI and pre-commit enforce
pre-commit run --all-files

# Test suite: GUI-free checks (safe anywhere) / full interactive run (user only)
tests/manual-test.sh --safe-only
tests/manual-test.sh

# Diagnostic dump of the FortiClient UI tree, tunnel interfaces, and Keychain entries
bash forti-debug.scpt

# Cut a CalVer release (tag vYYYY.MM.DD[.N] + GitHub release); preview first
./release.sh --dry-run
./release.sh

# Verify the tunnel independently of the GUI
ifconfig | grep -E "^(utun|ipsec)"
```

Safe partial tests without touching the GUI: `osascript forti.scpt` (usage error, exit 1) and `osascript forti.scpt NoSuchProfile` (Keychain error, exit 1) — both fail before FortiClient is launched.

Full manual testing requires FortiClient installed with profiles already configured in its GUI, Accessibility permission granted to the terminal, and a Keychain item per profile (service `forti-vpn-<ProfileName>`, account = username, password = password; case-sensitive match with the FortiClient "VPN Name" dropdown).

## Exit-code contract

`forti.scpt` / `forti-disconnect.scpt` exit 0 on success (including "already connected" / "not connected") and 1 on failure. `osascript` maps **every** script error to exit status 1 — distinct exit codes are impossible without abandoning the `osascript forti.scpt` invocation form, so don't try. Instead, each failure mode raises `error "message" number N` and the number lands in the stderr text (`... (N)`). The number assignments (64 usage, 2 keychain, 3 window/accessibility tree, 4 profile missing, 5 UI element missing, 6 connect/auto-disconnect timeout, 7 externally started connect finished on a different profile, 8 FortiClient not installed) are documented in each script's header and in MANUAL.md — keep all three in sync when adding failure modes.

`forti-status.scpt` inverts the contract: exit 0 means **connected** (the profile name is on stdout), exit 1 means **not connected or undeterminable**. Since osascript can only exit non-zero via an error, the ordinary "nothing connected" result is raised as `error … number 1` (silent stdout), and `number 3` distinguishes "FortiClient is running but its accessibility tree could not be read". The exit code, not stdout emptiness, is the authoritative connected/not signal. Same sync rule (header + MANUAL.md) applies.

## File naming quirk

`forti-debug.scpt` is actually a **bash** script (shebang `#!/bin/bash`) despite the `.scpt` extension; it embeds AppleScript via `osascript` heredocs. Because of the extension, shellcheck must be explicitly forced onto it: the pre-commit hook needs both `files: forti-debug\.scpt$` and `types: [file]` (overriding the hook's default `types: [shell]`, which never matches `.scpt`), and CI invokes `shellcheck --shell=bash` on it by name. Don't "simplify" either config — the hook silently stops running.

## How the automation works (key constraints)

- Shared handlers (`buildIndex`/`findElement`, `activeProfileName`, `isConnected`, the progress bar, `notifyOptional`, `waitForWindow`/`safeWindowContents`/`waitForTree`) live **once** in `src/lib/*.applescript` and are inlined into each tool by `build.sh`. Change behavior in `src/`, run `./build.sh`, and the pre-commit/CI `--check` catches a stale commit. Don't hand-edit the generated `.scpt`.
- FortiClient 7.x renders its UI in an embedded Chromium web view whose accessibility tree is hidden by default. All three tools enable it and wait for it through the **single shared `waitForTree` handler** (`src/lib/window.applescript`): it sets the `AXManualAccessibility` attribute on the process — which **resets on every app restart**, so it must run on every invocation — then **polls** for the tree to populate (20 × 0.3 s, anchored on the "VPN Name" popup or the Disconnect button) and returns the **indexed tree** (see `buildIndex` below), not the raw `entire contents`. Setting the attribute only *exposes* the tree; *reading* it is what needs the web view to have rendered, so polling (same philosophy as `waitForWindow`) replaces the old blind `delay`: a warm app incurs no wait, a cold launch gets up to ~6 s. The set is wrapped in `try … on error` that **logs a warning** (per the no-silent-swallow rule) and proceeds; if the tree truly is not exposed, `waitForTree` returns the last (possibly empty) index and the caller's element lookups raise a numbered error 3/5. `waitForTree` is read-only (never activates or focuses the app), so `forti-status.scpt` uses it too — but `forti-status.scpt` keeps its own inline `count of windows` check (error 3) *before* the poll, since it must fast-fail rather than wait out a cold launch it never triggers.
- UI elements are located by role + name (`AXPopUpButton`/"VPN Name", `AXTextField`/"Username"/"Password", `AXButton`/"Connect"/"Disconnect"), never by positional path: the web view's group hierarchy is deeply nested and changes between FortiClient versions. **Performance-critical detail:** reading `role`/`name` off a live element is one Apple Event that re-resolves a ~14-level Chromium specifier (~17 ms each), so the tree is walked **once** by the shared `buildIndex` (`src/lib/find-element.applescript`) into parallel `{elemRefs, elemRoles, elemNames}` lists, and `findElement` matches that index **in memory** (zero Apple Events). The fetch (`entire contents`) is cheap (~40 ms); the per-element reads are the cost, so paying them once instead of per-lookup (the flow ran ~6 passes) is the whole speedup. Everywhere the raw `elems` list used to flow, the index record now flows; `buildIndex` is the **one** place that still iterates live references.
- The web view may re-render after the profile switch, so the index is rebuilt (`my buildIndex(entire contents of window 1)`) before filling the credential fields.
- The "VPN Name" dropdown is opened **only when its current value differs** from the requested profile — clicking the currently-selected menu item fails in the web view (field-observed as a spurious error 4), so don't "simplify" the skip away.
- Profile selection in the open dropdown is **multi-strategy with value verification**: `menu item … of menu 1` → bare `menu item …` → typed-prefix (`keystroke` + Enter), each allowed to fail silently; success means the popup's `value` re-reads as the requested profile. `click menu item` throwing is normal (field-observed even for items visibly present in the menu) — never treat the click itself as the success signal.
- Connection state is detected by polling (15 × 2 s) for the **Disconnect button plus the `Duration` static text**. The Disconnect button alone means only "connecting" (it doubles as a cancel during that phase — field-observed); the status labels (`Duration`/`Bytes Received`/`Bytes Sent`) appear only in the truly connected view. Never use the Disconnect button alone as the success signal. This "fully connected" test is the shared `isConnected` handler — keep it as the single definition, used by both `forti.scpt` and `forti-status.scpt`.
- Poll loops read the tree via `safeWindowContents`, which fetches `entire contents` and returns it **already indexed** (`buildIndex`), or the **empty index** (`emptyIndex`: `{elemRefs:{}, ...}`) when `window 1` momentarily vanishes (FortiClient hides and re-shows its window mid-(dis)connect). A transient disappearance therefore becomes a continued poll → numbered timeout (error 6), not a raw `-1719` crash. Each poll iteration rebuilds the index — accepted: the loop already waits on a 2 s `delay`, so the extra pass is in the noise. Don't replace it with a bare `entire contents of window 1` inside a poll.
- In the **connected** view the form (popup, text fields) does not exist at all; the active profile is the static text that follows the `"VPN Name"` label static text in the index's document order (`activeProfileName` handler; the index preserves `entire contents` order). This order-anchored lookup is the deliberate exception to "no positional addressing" — it anchors on a named label, not on group indices.
- When a **different** profile is fully connected at start, `forti.scpt` disconnects automatically (clicks Disconnect, polls for the Connect button to come back) and proceeds with the normal connect flow. Error 7 fires only when an *in-flight* attempt (started outside the script) completes on a different profile — the script never cancels an in-flight attempt. When the active profile **cannot be read at all** (`activeProfileName` returns `""` even after one re-read), `forti.scpt` reports success but **leaves the window visible** (does not hide it) — it must not silently hide a connection it cannot identify. Don't "optimize" this back into the hide-and-claim-success path.
- `forti-disconnect.scpt` bails out early (exit 0, "nothing to disconnect") when no FortiClient **process** exists — like `forti-status.scpt`, it assumes no process ⇒ no tunnel, which also avoids launching the app (or the "Choose Application" dialog when it is not installed) just to tear down a connection that does not exist. Both `forti.scpt` and `forti-disconnect.scpt` then poll for the window via `waitForWindow` (20 × 0.5 s, error 3 on timeout) rather than a blind `delay`.
- Notifications go through the shared `notifyOptional` handler, which **never fails the operation**: a notification that can't be posted (disabled, no permission, no GUI session under launchd/cron) is logged and ignored, so a successful connect/disconnect never exits 1 over a missing notification.
- Element-not-found errors inside the search loops are intentionally swallowed with bare `try` blocks — the loops probe many elements that lack a `name`; actual failures are detected with found-flags after each loop and raised as numbered errors.
- In `forti.scpt`, the Keychain lookup happens **before** the GUI is touched so a missing item fails fast; the password (`-w`) is fetched first because the username's awk pipeline masks a failing `security` (the pipeline exits with awk's status).
- On a cold launch the FortiClient window can take seconds to appear, so the tools poll for it via the shared `waitForWindow` handler (20 × 0.5 s, error 3 on timeout) instead of using a blind delay — keep this; don't replace it with a fixed `delay`.
- **Background operation (no focus stealing).** The tools drive FortiClient without bringing it to the front. Startup goes through the shared `showInBackground` handler (`src/lib/window.applescript`) — `launch` (not `activate`) plus an un-hide of a previously hidden window, never `set frontmost` — and reading the tree, `set value` on fields, and `click <element>` are all Accessibility actions that work on a background window. There are exactly **two** deliberate foreground moments, both in `forti.scpt` and both via `src/lib/focus.applescript`: (1) a **real profile switch** — the native `<select>` dropdown only accepts a selection (menu click *or* keystroke) while the app is frontmost, and writing its `AXValue` directly is silently ignored by the web view (field-confirmed via probe), so `focusFortiClient`/`restoreFront` bracket the **whole** selection, and only when `currentProfile` differs from the request (a same-profile reconnect and all of `forti-disconnect.scpt` never leave the background); (2) FortiClient **raises its own window on connect**, so the connect poll calls `pushBack(callerApp)` every ~0.3 s to shove the caller's app back on top, bounding the flash to a tick. The caller app is captured once at startup. Don't reintroduce `activate`/`set frontmost` on the normal path, and don't widen the profile-switch foreground to the rest of the flow.
- Hard-coded `delay` values throughout are timing-dependent workarounds, not arbitrary; MANUAL.md's debugging table documents which ones to increase for which failure mode.
- Console progress: step lines use `log` (osascript sends them to stderr); the tqdm-style bar is written to **`/dev/tty`**, NOT `>&2`, because `do shell script` **discards stderr on success** (TN2065) — a `printf ... >&2` inside it outputs nothing. No-terminal contexts (launchd/cron) make the printf fail; that error is deliberately swallowed. Error messages must stay the **last** stderr line (scripts raise errors only after `endProgress`), since consumers parse the trailing `(N)` from the final line.

## Docs maintenance

README.md is deliberately short and non-technical — keep it that way; technical detail belongs in MANUAL.md. MANUAL.md's debugging table (symptom → cause/fix) is the project's institutional knowledge about FortiClient's accessibility quirks. When changing element-lookup logic, delays, or error numbers, keep the script headers, MANUAL.md's exit-code tables, and that debugging table in sync.
