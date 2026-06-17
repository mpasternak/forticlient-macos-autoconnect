#!/usr/bin/osascript
-- forti-status.scpt — report the currently-connected FortiClient VPN profile.
--
-- Usage:   osascript forti-status.scpt
--
-- Prints the active VPN profile name to STDOUT and exits 0 when a tunnel is
-- fully up; prints nothing and exits 1 when nothing is connected. The exit
-- code — not stdout emptiness — is the authoritative connected/not signal, so
-- `osascript forti-status.scpt >/dev/null` works as a boolean test and
-- `name=$(osascript forti-status.scpt)` captures the profile name.
--
-- Read-only and quiet: it never launches FortiClient, never changes the VPN
-- state, and does not bring the window to the foreground. If a connection is
-- in progress it waits up to ~30 s for the tunnel to come up, then reports it.
--
-- Exit status: 0 on a live tunnel, 1 otherwise. osascript can only exit
-- non-zero by raising an error, so the specific reason is carried in the
-- stderr message and its error number:
--    1  nothing connected (FortiClient not running, the Connect form is
--       showing, or an in-progress attempt did not come up within ~30 s)
--    3  FortiClient is running but its accessibility tree could not be read
--       (no window exposed, or Accessibility permission not granted)
--
-- A fully-up tunnel whose profile name cannot be read still exits 0 (connected
-- is connected; the exit code is authoritative) — stdout is then empty.

--#include lib/find-element.applescript
--#include lib/active-profile.applescript
--#include lib/is-connected.applescript
--#include lib/progress.applescript
--#include lib/window.applescript

on run argv
	tell application "System Events"
		-- never launch FortiClient: if it is not running, no tunnel can be up
		if not (exists process "FortiClient") then
			error "No VPN connected (FortiClient is not running)." number 1
		end if
		tell process "FortiClient"
			-- a status query must not steal focus, so we never activate the app
			-- or bring its (possibly hidden) window forward; nor do we wait for a
			-- cold launch (no waitForWindow) — no window yet means nothing to read.
			if (count of windows) is 0 then
				error "FortiClient is running but exposes no window to read — the accessibility tree is not available (grant Accessibility permission; see MANUAL.md)." number 3
			end if
		end tell
	end tell
	-- enable the Chromium tree and poll for it to populate (shared handler;
	-- read-only, so it does not steal focus). Already set during the live
	-- connection; re-setting is idempotent and covers a restarted app.
	set elems to my waitForTree()

	-- Fully connected → report the active profile (stdout) and exit 0.
	if my isConnected(elems) then return my activeProfileName(elems)

	-- Disconnect button but no Duration label: a connection is in progress —
	-- wait (up to ~30 s) for it to come fully up, then report it.
	if my findElement(elems, "AXButton", "Disconnect") is not missing value then
		log "* a connection is in progress — waiting for it to come up"
		set connected to false
		my progressBar("connecting", 0, 30)
		repeat with i from 1 to 15
			delay 2
			my progressBar("connecting", i * 2, 30)
			set elems to my safeWindowContents()
			if my isConnected(elems) then
				set connected to true
				exit repeat
			end if
		end repeat
		if connected then
			my endProgress("connecting: tunnel is up")
			return my activeProfileName(elems)
		end if
		my endProgress("connecting: not connected")
		error "No VPN connected (a connection attempt did not come up within ~30 s)." number 1
	end if

	-- A visible Connect button means the state is unambiguously "down";
	-- otherwise neither button was found and the tree is unreadable.
	if my findElement(elems, "AXButton", "Connect") is not missing value then
		error "No VPN connected." number 1
	end if
	error "Could not read FortiClient's UI — neither Connect nor Disconnect found; the accessibility tree is not exposed (see MANUAL.md)." number 3
end run
