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
