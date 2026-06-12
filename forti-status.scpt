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

-- Return the first element of `elems` with the given role and name, or
-- `missing value`. The bare try swallows errors from probing elements that
-- have no name attribute — actual lookup failure is the missing value result.
on findElement(elems, theRole, theName)
	tell application "System Events"
		repeat with e in elems
			try
				if (role of e is theRole) and (name of e is theName) then return contents of e
			end try
		end repeat
	end tell
	return missing value
end findElement

-- In the *connected* view the form is gone and the active profile is shown
-- as the static text that follows the "VPN Name" label static text in
-- document order ("entire contents" returns elements in that order).
-- Returns "" when it cannot be determined.
on activeProfileName(elems)
	tell application "System Events"
		set seenLabel to false
		repeat with e in elems
			try
				if role of e is "AXStaticText" then
					if seenLabel then
						return name of e
					else if name of e is "VPN Name" then
						set seenLabel to true
					end if
				end if
			end try
		end repeat
	end tell
	return ""
end activeProfileName

-- Console progress, emitted only while waiting for an in-progress connection;
-- the common already-connected query stays silent so stdout (the profile name)
-- is clean. Step lines use `log` (osascript sends them to stderr); the
-- overwriting bar must go straight to /dev/tty: `do shell script` DISCARDS
-- stderr on success (TN2065), so "printf ... >&2" outputs nothing. /dev/tty
-- also keeps redirected stdout/stderr clean; with no controlling terminal
-- (launchd, cron) the printf fails and the bar is skipped.
on emitProgress(lineText)
	try
		do shell script "printf '\\r%-60s' " & quoted form of lineText & " > /dev/tty"
	on error
		-- no controlling terminal — the `log` lines still carry the progress
	end try
end emitProgress

on endProgress(lineText)
	try
		do shell script "printf '\\r%-60s\\n' " & quoted form of lineText & " > /dev/tty"
	on error
		-- no controlling terminal — the `log` lines still carry the progress
	end try
end endProgress

-- tqdm-style bar:  label [########------------] 12/30 s
on progressBar(labelText, elapsed, total)
	set barWidth to 20
	set filledCount to (barWidth * elapsed) div total
	set theBar to ""
	repeat filledCount times
		set theBar to theBar & "#"
	end repeat
	repeat (barWidth - filledCount) times
		set theBar to theBar & "-"
	end repeat
	my emitProgress(labelText & " [" & theBar & "] " & elapsed & "/" & total & " s")
end progressBar

-- True when `elems` shows a fully-up tunnel: a Disconnect button *and* a
-- Duration status label. The Disconnect button alone only means a connect is
-- in progress (it doubles as a cancel then) — same criterion forti.scpt uses.
on isConnected(elems)
	return (my findElement(elems, "AXButton", "Disconnect") is not missing value) and (my findElement(elems, "AXStaticText", "Duration") is not missing value)
end isConnected

on run argv
	tell application "System Events"
		-- never launch FortiClient: if it is not running, no tunnel can be up
		if not (exists process "FortiClient") then
			error "No VPN connected (FortiClient is not running)." number 1
		end if
		tell process "FortiClient"
			-- enable the Chromium web view's accessibility tree without bringing
			-- the (possibly hidden) window forward — a status query must not
			-- steal focus. Already set since the live connection; re-setting is
			-- idempotent and covers an app that was restarted meanwhile.
			try
				set value of attribute "AXManualAccessibility" to true
			end try
			delay 0.5
			if (count of windows) is 0 then
				error "FortiClient is running but exposes no window to read — the accessibility tree is not available (grant Accessibility permission; see MANUAL.md)." number 3
			end if
			set elems to entire contents of window 1
		end tell
	end tell

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
			tell application "System Events"
				tell process "FortiClient"
					set elems to entire contents of window 1
				end tell
			end tell
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
