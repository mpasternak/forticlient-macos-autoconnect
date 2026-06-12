# Manual

Technical reference for `forticlient-macos-autoconnect`. For a quick start,
see [README.md](README.md).

## Files

| File                    | Purpose                                          |
| ----------------------- | ------------------------------------------------ |
| `forti.scpt`            | Connects to a given VPN profile                  |
| `forti-disconnect.scpt` | Disconnects the active tunnel                    |
| `forti-status.scpt`     | Prints the connected profile name, or nothing    |
| `forti-debug.scpt`      | Diagnostic dump of the FortiClient UI tree (a bash script, despite the extension) |
| `release.sh`            | Cuts a CalVer release (git tag + GitHub release) |

## Requirements

- macOS with FortiClient (free "VPN only" / ZTNA agent) installed
- VPN profiles already configured **once, manually, in the FortiClient GUI** —
  the script selects an existing profile by name, it does not create profiles
- Accessibility permission for whatever runs the script (Terminal, iTerm2,
  etc.): *System Settings → Privacy & Security → Accessibility*
- Optionally, notification permission for `osascript`/Script Editor:
  *System Settings → Notifications*

## Keychain setup

The connect script reads one Keychain item per VPN profile from your **login
keychain**. The item's *service name* must be `forti-vpn-<ProfileName>`, where
`<ProfileName>` matches the profile name shown in FortiClient's "VPN Name"
dropdown **exactly, including letter case**. The item's *account* field is
your VPN username; the *password* field is your VPN password.

Add an entry (you will be prompted for the password interactively, so it
never lands in your shell history):

```bash
security add-generic-password -s forti-vpn-WorkVPN -a your-vpn-username -w
```

Repeat for every profile. Different profiles can have different usernames —
each entry carries its own:

```bash
security add-generic-password -s forti-vpn-HomeVPN -a your-vpn-username -w
security add-generic-password -s forti-vpn-LabVPN -a your-vpn-username -w
```

Verify an entry:

```bash
# password
security find-generic-password -s forti-vpn-WorkVPN -w

# username (stored in the "acct" attribute)
security find-generic-password -s forti-vpn-WorkVPN | awk -F'"' '/"acct"/{print $4}'
```

On first use, macOS may ask whether `security` may access the item — choose
**Always Allow**, otherwise you will be prompted on every connection.

### Fixing or removing an entry

If you stored a wrong password or username, delete the item and re-add it:

```bash
security delete-generic-password -s forti-vpn-WorkVPN
security add-generic-password -s forti-vpn-WorkVPN -a correct-username -w
```

Avoid `add-generic-password -U` to "update" an entry when the username
changed — matching is done on service *and* account, so a changed account
creates a duplicate item instead of updating the existing one. Delete and
re-add is the safe path.

Note: passwords stored in the **Passwords** app (iCloud Keychain / website
passwords) live in a separate protected keychain that the `security` CLI
cannot read. You must create these dedicated login-keychain entries even if
the same password already exists in the Passwords app.

## Connecting

```bash
osascript forti.scpt <ProfileName> [username]
```

Examples:

```bash
osascript forti.scpt WorkVPN
osascript forti.scpt HomeVPN
osascript forti.scpt HomeVPN some-other-username   # optional username override
```

What happens:

1. Credentials are read from the Keychain (before the GUI is touched, so a
   missing Keychain item fails fast). When a username is given on the command
   line, the Keychain account attribute is not consulted at all.
2. FortiClient is activated; the script waits up to 10 s for its window to
   appear (a cold launch can be slow), then enables the accessibility tree.
3. If the tunnel is already up — a **Disconnect** button together with the
   status labels (**Duration**, **Bytes Received**, **Bytes Sent**); the
   Disconnect button alone only means "connecting", where it doubles as a
   cancel — the script checks the active profile name (in the connected view
   the form is gone and the profile is the static text following the
   "VPN Name" label). On a match it reports "Already connected" and exits
   successfully; on a mismatch it posts a "Switching" notification,
   **disconnects automatically**, waits for the form to come back, and
   continues with the normal connect flow. If a connection attempt is still
   in progress, the script does not touch the form and simply waits for the
   outcome (step 7); should that attempt turn out to have targeted a
   different profile, the script fails with error 7.
4. The profile is selected in the "VPN Name" dropdown — skipped when the
   dropdown already shows the requested profile, because clicking the
   currently-selected menu item fails in FortiClient's web view. Selection
   tries native menu-item addressing (`menu 1`, then the bare form) and
   falls back to typed-prefix selection (typing the name + Enter); success
   is verified by re-reading the dropdown's value, not by the click.
5. Username and password are typed into the form.
6. **Connect** is clicked.
7. The script polls for up to ~30 s until the **Disconnect** button *and*
   the **Duration** status label are both present. The Disconnect button
   alone is not used as the success signal — FortiClient shows it already
   while connecting; the status labels appear only once the tunnel is
   actually up. (FortiClient briefly hides and re-shows its window around
   the moment the connection completes; the script hides it only after the
   labels appear, so it stays hidden.)
8. On success the FortiClient window is hidden (the app keeps running and
   holds the tunnel) and a "Connected" notification is shown; on failure you
   get a "Failed" notification and a non-zero exit.

## Disconnecting

```bash
osascript forti-disconnect.scpt
```

Clicks **Disconnect**, waits up to ~30 s for the button to flip back to
**Connect**, hides the window and posts a notification. If no tunnel is up,
it reports "Not connected" and exits successfully.

## Checking status

```bash
osascript forti-status.scpt
```

Prints the name of the currently-connected VPN profile to **stdout** and
exits **0**; prints nothing and exits **1** when no tunnel is up. The exit
code — not whether stdout is empty — is the authoritative connected/not
signal, so both of these work:

```bash
# boolean test
if osascript forti-status.scpt >/dev/null 2>&1; then echo "VPN is up"; fi

# capture the active profile name
profile=$(osascript forti-status.scpt 2>/dev/null) && echo "connected to $profile"
```

Unlike `forti.scpt` / `forti-disconnect.scpt`, status is **read-only and
quiet**: it never launches FortiClient (a tunnel cannot be up if the app is
not running), never changes the VPN state, and does not bring the window to
the foreground or steal focus — it only reads the accessibility tree. In the
common already-connected case it emits no step lines and no progress bar, so
its stdout stays clean for use in `$(…)`.

If a connection is **in progress** when you ask (the Disconnect button is
showing but the tunnel is not yet fully up), status waits up to ~30 s for it
to come up — showing the same progress bar as the connect flow — and then
reports the profile; if it does not come up in time, status treats it as not
connected. Notifications are never posted (it is a passive query).

## Console progress

Both scripts narrate their steps on **stderr** (via AppleScript `log`) and
show a tqdm-style overwriting progress bar during the connect/disconnect
waits:

```
* credentials for 'WorkVPN' loaded from the Keychain
* activating FortiClient
* profile 'WorkVPN' selected
* credentials filled, Connect clicked
connecting [########------------] 12/30 s
```

The bar is written directly to your terminal (`/dev/tty`), not to
stdout/stderr — redirections and command substitutions stay clean, and the
bar still shows live even when stderr is captured (as the test suite
does). Without a controlling terminal (launchd, cron) the bar is skipped
automatically; the `log` step lines remain on stderr.

Implementation note: the bar cannot use `printf ... >&2` inside
`do shell script`, because `do shell script` discards stderr on success
(it only surfaces in the error message on failure) — hence `/dev/tty`.

## Exit codes

Both scripts exit **0 on success** and **1 on any failure** — suitable for
chaining (`vpn-work && ssh internal-host`). `osascript` maps every script
error to exit status 1, so finer-grained failure reasons cannot be expressed
in the exit code itself; instead each failure carries a distinct **error
number in the stderr message**, e.g.:

```
forti.scpt: execution error: No Keychain item with service name 'forti-vpn-X' ... (2)
```

`forti.scpt` error numbers:

| #  | Meaning                                                            |
| -- | ------------------------------------------------------------------ |
| 64 | Usage error — no profile argument given                            |
| 2  | Keychain item missing, unreadable, or without an account attribute |
| 3  | FortiClient window did not appear, or "VPN Name" popup not found (accessibility tree not exposed?) |
| 4  | Profile not present in the "VPN Name" dropdown                     |
| 5  | Expected UI element not found (Username/Password field, Connect)   |
| 6  | Connection, or auto-disconnect during a profile switch, timed out after ~30 s |
| 7  | An externally started connection completed on a different profile  |
| 8  | FortiClient is not installed or failed to launch                   |

`forti-disconnect.scpt` error numbers:

| # | Meaning                                                             |
| - | ------------------------------------------------------------------- |
| 3 | Neither "Disconnect" nor "Connect" button found                     |
| 6 | Still connected after ~30 s                                         |

`forti-status.scpt` exits **0** when a tunnel is up (printing the profile
name to stdout) and **1** otherwise. Because exit 1 is also how it signals the
ordinary "nothing connected" result, the trailing `(N)` distinguishes the two
exit-1 cases:

| # | Meaning                                                                |
| - | ---------------------------------------------------------------------- |
| 1 | Nothing connected — FortiClient not running, the Connect form is showing, or an in-progress attempt did not come up within ~30 s (a *normal* negative result, not a fault; stdout is empty) |
| 3 | FortiClient is running but its accessibility tree could not be read (no window exposed, or Accessibility permission not granted) — status genuinely *could not tell* |

A caller that only cares whether a VPN is up should check the exit code (or
non-empty stdout) and ignore the number; the `(3)` case is worth surfacing
because it means a setup problem, not "disconnected".

To extract the error number in a shell script, parse the trailing `(N)` from
stderr. Progress lines also land on stderr, but the `execution error` line
is always the **last** one — parse the final line only (as
`tests/manual-test.sh` does).

## Testing

There is an interactive test suite for **manual, attended** runs:

```bash
tests/manual-test.sh                # full suite — drives the real GUI
tests/manual-test.sh --safe-only    # only the GUI-free checks
```

The safe tests (syntax compilation of all three scripts, usage error,
missing Keychain item) run unconditionally. The GUI tests connect and
disconnect **real VPN tunnels**: the suite asks for confirmation once, then
runs the whole GUI sequence unattended (~3–5 minutes), starting with a
cleanup disconnect. Covered scenarios: disconnect from any state, fresh
connect, already-connected fast path, automatic profile switch in both
directions, and disconnect-when-not-connected. Each test verifies the exit
status and, for failures, the `(N)` error number on stderr.

The GUI section also checks `forti-status.scpt` against the live state:
after each connect/switch it asserts that status prints the expected profile
name to stdout and exits 0, and after the final disconnect that it prints
nothing and exits 1.

The two profiles used default to `IHIT` and `IPIS`; override them with
`FORTI_TEST_PROFILE_A` / `FORTI_TEST_PROFILE_B`. Both must exist in
FortiClient's dropdown and have `forti-vpn-<name>` Keychain items (the
suite warns upfront if not).

## Releasing

Versioning is **CalVer**, and a git tag is the only version record — there
is no package manifest to bump. The tag for a day's first release is
`vYYYY.MM.DD`; a second, third, … release on the same day appends a micro:
`vYYYY.MM.DD.1`, `vYYYY.MM.DD.2`, and so on.

```bash
./release.sh             # cut and push today's release
./release.sh --dry-run   # preview the version and notes, change nothing
```

`release.sh` refuses to run unless the working tree is clean, you are on
`main`, and `HEAD` is already pushed (the tag must point at a published
commit). It then runs the GUI-free safe tests, computes the next CalVer tag,
creates an **annotated** tag whose body is the commit subjects since the
previous tag, pushes the tag, and — if `gh` is installed and authenticated —
creates a matching GitHub release. Useful flags:

| Flag             | Effect                                                       |
| ---------------- | ------------------------------------------------------------ |
| `--dry-run`      | Print the computed version and release notes, then stop      |
| `--no-gh`        | Create and push the tag, but skip the GitHub release         |
| `--skip-tests`   | Skip the safe-test gate (not recommended)                    |
| `--allow-branch` | Permit releasing from a branch other than `main`             |

To undo a mistaken local tag before it is pushed: `git tag -d <version>`.
Once a tag is pushed (and especially once a GitHub release exists), prefer
cutting a new micro over deleting the published tag.

## Debugging

Run the bundled diagnostic script:

```bash
bash forti-debug.scpt
```

It enables `AXManualAccessibility`, dumps the window list and the full UI
tree, prints every button / text field / popup it can see together with its
name, and lists active tunnel interfaces. Compare its output with what the
main script expects (`text field "Username"`, `text field "Password"`,
`pop up button "VPN Name"`, `button "Connect"`).

Common failures and what they mean:

| Symptom                                                      | Cause / fix                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| `osascript is not allowed assistive access (-25211)` or `(1002)` | The terminal app has no Accessibility permission. Grant it in *System Settings → Privacy & Security → Accessibility*, then restart the terminal. |
| Error `(3)` — "No FortiClient window appeared within 10 s"   | FortiClient launched but never showed its window (very slow machine, or the app is stuck). Open FortiClient manually once and retry; if it is consistently slow, increase the `repeat 20 times` window-wait loop. |
| Error `(3)` — popup or buttons not found                     | The accessibility tree is not exposed (the `AXManualAccessibility` call failed or ran too early — increase the `delay`), or the element has a different (e.g. localized) name. Run `forti-debug.scpt` and check the real names. |
| Error `(2)` — `security: ... could not be found in the keychain. (44)` | No Keychain item for this profile. Check the service name with `security find-generic-password -s forti-vpn-<ProfileName>` — remember it is case-sensitive — and add the entry as in the Keychain section. |
| Error `(2)` — "no readable account attribute"                | The item exists but was created without `-a`, or the username contains non-ASCII characters (`security` then prints the account as hex, which the script cannot parse). Delete and re-add the item with `-a <username>`, or pass the username as the second argument. |
| Error `(4)` — profile is not selected / wrong profile connects | The argument must match the name shown in the dropdown entry. (The Keychain *service name* is the case-sensitive part; AppleScript's own string matching is case-insensitive.) The script tries `menu item … of menu 1 of` the popup, the bare `menu item … of` form, and finally typed-prefix selection (`keystroke profileName` + Enter), and raises (4) only when the dropdown's value still differs afterwards. |
| Error `(4)` although the profile is visibly in the dropdown  | All three selection strategies failed, or the popup's `value` reads differently than the visible label (the verification compares against `value`). Run `forti-debug.scpt` and compare what the popup's value actually returns with what is displayed. |
| Error `(7)` — connection completed on a different profile    | Rare race: a connect that was already in progress when the script started (begun by hand or by another invocation) finished on another profile. The script never interferes with an in-flight attempt; run `osascript forti-disconnect.scpt`, then connect again. When a different profile is already *fully* connected at start, the script disconnects and switches automatically instead — the active profile is read from the static text that follows the "VPN Name" label in the connected view (the dropdown does not exist there). |
| Script declared success / hid the window while still connecting | Should not happen: the poll requires the `Duration` status label, not just the Disconnect button (which FortiClient shows already during the connecting phase, as a cancel). If it recurs, your FortiClient version may label the status fields differently — run `forti-debug.scpt` while connected and compare. |
| Error `(8)` — FortiClient not found                          | FortiClient.app is not installed (or not in `/Applications`). Install the free "VPN only" client and configure your profiles once in its GUI. |
| Fields stay empty although the script ran                    | Some web-view fields reject `set value`. Replace the assignment with: `click e`, then `keystroke "a" using command down`, then `keystroke theValue`. |
| Error `(6)` but the VPN is up                                | The 30 s poll timed out (slow gateway / 2FA prompt). Increase the `repeat 15 times` / `delay 2` values. |
| Everything worked yesterday, fails after FortiClient restart | Expected — `AXManualAccessibility` resets when the app restarts. The script re-enables it on every run; if you experimented manually, re-run the script rather than relying on a previous state. |

To verify the tunnel independently of the GUI:

```bash
ifconfig | grep -E "^(utun|ipsec)"
ping -c1 -t2 <internal-host>
```

## How it works

FortiClient 7.x renders its UI in an embedded Chromium view. Chromium-based
apps expose their accessibility tree only on demand; setting the
`AXManualAccessibility` attribute on the application element switches it on,
after which the form controls become visible to AppleScript's *System
Events*. The scripts then locate elements by role and name with a recursive
`entire contents` search, so they are independent of window position and of
the (deeply nested, version-dependent) group hierarchy.
