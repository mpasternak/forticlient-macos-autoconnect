# Manual

Technical reference for `forticlient-macos-autoconnect`. For a quick start,
see [README.md](README.md).

## Files

| File                    | Purpose                                          |
| ----------------------- | ------------------------------------------------ |
| `forti.scpt`            | Connects to a given VPN profile                  |
| `forti-disconnect.scpt` | Disconnects the active tunnel                    |
| `forti-debug.scpt`      | Diagnostic dump of the FortiClient UI tree (a bash script, despite the extension) |

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
   missing Keychain item fails fast).
2. FortiClient is activated and its accessibility tree is enabled.
3. If the tunnel is already up (a **Disconnect** button is showing), the
   script reports "Already connected" and exits successfully.
4. The profile is selected in the "VPN Name" dropdown.
5. Username and password are typed into the form.
6. **Connect** is clicked.
7. The script polls for up to ~30 s until the button changes to
   **Disconnect**.
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
| 2  | Keychain item missing or unreadable                                |
| 3  | "VPN Name" popup not found (accessibility tree not exposed?)       |
| 4  | Profile not present in the "VPN Name" dropdown (case-sensitive)    |
| 5  | Expected UI element not found (Username/Password field, Connect)   |
| 6  | Connection failed or timed out after ~30 s                         |

`forti-disconnect.scpt` error numbers:

| # | Meaning                                                             |
| - | ------------------------------------------------------------------- |
| 3 | Neither "Disconnect" nor "Connect" button found                     |
| 6 | Still connected after ~30 s                                         |

To extract the error number in a shell script, parse the trailing `(N)` from
stderr.

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
| Error `(3)` — popup or buttons not found                     | The accessibility tree is not exposed (the `AXManualAccessibility` call failed or ran too early — increase the `delay`), or the element has a different (e.g. localized) name. Run `forti-debug.scpt` and check the real names. |
| Error `(2)` — `security: ... could not be found in the keychain. (44)` | No Keychain item for this profile. Check the service name with `security find-generic-password -s forti-vpn-<ProfileName>` — remember it is case-sensitive — and add the entry as in the Keychain section. |
| Error `(4)` — profile is not selected / wrong profile connects | The argument must match the dropdown entry exactly (case-sensitive). If clicking the menu item misbehaves, replace the `click menu item` line with `keystroke profileName` followed by `key code 36` (Enter) after opening the popup — native menus select by typed prefix. |
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
