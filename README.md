# forticlient-macos-autoconnect

Connect to your FortiClient VPN on macOS with a single terminal command — no
clicking through the FortiClient window, no typing passwords.

FortiClient for macOS has no command line of its own. These scripts drive the
FortiClient app for you: they pick your VPN profile, fill in your username and
password (stored safely in the macOS Keychain), press **Connect**, and tell
you when the tunnel is up.

## What you need

- FortiClient (the free "VPN only" version is fine) installed, with your VPN
  profile(s) already set up once in its window
- Permission for your terminal app to control other apps: *System Settings →
  Privacy & Security → Accessibility* — add Terminal / iTerm2 / whatever you
  use

## Quick start

**1. Save your VPN password in the Keychain** (one time per profile — replace
`WorkVPN` with your profile's name exactly as FortiClient shows it):

```bash
security add-generic-password -s forti-vpn-WorkVPN -a your-vpn-username -w
```

You'll be asked to type the password, so it never shows up on screen or in
your shell history.

**2. Connect:**

```bash
osascript forti.scpt WorkVPN
```

The FortiClient window pops up briefly, connects, then hides itself. You get
a notification when the tunnel is up.

**3. Disconnect:**

```bash
osascript forti-disconnect.scpt
```

## Make it comfortable

Add aliases to your `~/.zshrc`:

```bash
alias vpn-work='osascript ~/bin/forti.scpt WorkVPN'
alias vpn-down='osascript ~/bin/forti-disconnect.scpt'
```

## Something not working?

See **[MANUAL.md](MANUAL.md)** — it covers Keychain management in detail,
exit codes for scripting, a troubleshooting table for every known failure,
and the bundled diagnostic script.

## Disclaimer

This is an independent, community-made tool. The author and this software are
in no way affiliated with, endorsed by, or sponsored by Fortinet, Inc.
*FortiClient* and *Fortinet* are trademarks of Fortinet, Inc. Use at your own
risk.

## License

MIT
