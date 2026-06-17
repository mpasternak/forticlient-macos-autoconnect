-- lib/window.applescript — FortiClient window helpers shared by the tools.

-- Poll up to ~10 s (20 × 0.5 s) for FortiClient to show a window; a cold
-- launch can take seconds. Returns true once a window exists, false on
-- timeout. Use this instead of a blind delay after activating the app.
on waitForWindow()
	tell application "System Events"
		tell process "FortiClient"
			repeat 20 times
				if (count of windows) > 0 then return true
				delay 0.5
			end repeat
		end tell
	end tell
	return false
end waitForWindow

-- `entire contents of window 1`, tolerant of the window momentarily
-- disappearing — FortiClient hides and re-shows it while (dis)connecting.
-- Returns {} on error so poll loops keep polling to a controlled, numbered
-- timeout instead of crashing on a raw AppleScript error.
on safeWindowContents()
	try
		tell application "System Events"
			tell process "FortiClient"
				return entire contents of window 1
			end tell
		end tell
	on error
		-- expected: the window is briefly absent mid-(dis)connect. The caller's
		-- poll timeout (error 6) is the real failure path, not this read.
		return {}
	end try
end safeWindowContents

-- Enable FortiClient's embedded Chromium accessibility tree, then poll for it
-- to populate, and return `entire contents of window 1`. Shared by all three
-- tools so the tree-readiness logic lives in one place.
--
-- AXManualAccessibility exposes the web view's tree and RESETS on every app
-- restart, so it must be set on every invocation. Setting it only *exposes*
-- the tree; *reading* it (entire contents) is the part that needs the web view
-- to have rendered — so we poll for that instead of a blind delay, the same
-- philosophy as waitForWindow. A warm app (already running, profile rendered)
-- is ready on the first probe, so there is no wasted wait; a cold launch gets
-- up to ~6 s (20 × 0.3 s). The anchor is the "VPN Name" popup (disconnected /
-- connecting view) OR the Disconnect button (connected view): either proves
-- the tree is exposed. Returns the contents once anchored, or the last
-- (possibly empty) read on timeout — the caller's element lookups then raise
-- the numbered error 3/5. safeWindowContents keeps a window that momentarily
-- vanishes from crashing the poll. Read-only: never activates or focuses the
-- app, so it is safe for the quiet status query too.
on waitForTree()
	tell application "System Events"
		tell process "FortiClient"
			try
				set value of attribute "AXManualAccessibility" to true
			on error errMsg
				log "* warning: could not set AXManualAccessibility (" & errMsg & ") — accessibility tree may be unavailable"
			end try
		end tell
	end tell
	set elems to {}
	repeat 20 times
		set elems to my safeWindowContents()
		if (my findElement(elems, "AXPopUpButton", "VPN Name") is not missing value) or (my findElement(elems, "AXButton", "Disconnect") is not missing value) then return elems
		delay 0.3
	end repeat
	return elems
end waitForTree
