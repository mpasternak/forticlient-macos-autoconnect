#!/usr/bin/osascript
-- forti-disconnect.scpt — disconnect the active FortiClient VPN tunnel.
--
-- Usage:   osascript forti-disconnect.scpt
--
-- Counterpart to forti.scpt: enables the accessibility tree, clicks
-- "Disconnect", waits for the button to flip back to "Connect", then hides
-- the FortiClient window and posts a notification. No credentials needed.
--
-- Exit status: 0 on success (disconnected, or no tunnel was up), 1 on any
-- failure. osascript maps every script error to exit status 1, so the
-- specific failure is carried in the stderr message and its error number:
--    3  neither "Disconnect" nor "Connect" button found
--       (accessibility tree not exposed?)
--    6  still connected after ~30 s

on run argv
	tell application "FortiClient" to activate
	delay 1.5

	tell application "System Events"
		tell process "FortiClient"
			set frontmost to true
			-- Same Chromium web-view workaround as in forti.scpt; resets on app
			-- restart, so it must run on every invocation.
			try
				set value of attribute "AXManualAccessibility" to true
			end try
			delay 0.5

			set elems to entire contents of window 1
			set disconnectClicked to false
			set alreadyDisconnected to false
			repeat with e in elems
				try
					if role of e is "AXButton" then
						if name of e is "Disconnect" then
							click e
							set disconnectClicked to true
							exit repeat
						else if name of e is "Connect" then
							-- the connect form is showing, so no tunnel is up
							set alreadyDisconnected to true
						end if
					end if
				end try
			end repeat

			if alreadyDisconnected and not disconnectClicked then
				set visible to false
				display notification "Not connected — nothing to disconnect" with title "FortiClient VPN" sound name "Glass"
				return
			end if
			if not disconnectClicked then
				error "Neither 'Disconnect' nor 'Connect' button found — the accessibility tree is probably not exposed. Run forti-debug.scpt and see MANUAL.md." number 3
			end if
		end tell
	end tell

	-- wait up to ~30 s for the button to flip back to "Connect"
	set disconnected to false
	repeat 15 times
		delay 2
		tell application "System Events"
			tell process "FortiClient"
				set elems to entire contents of window 1
				repeat with e in elems
					try
						if (role of e is "AXButton") and (name of e is "Connect") then
							set disconnected to true
							exit repeat
						end if
					end try
				end repeat
			end tell
		end tell
		if disconnected then exit repeat
	end repeat

	if disconnected then
		tell application "System Events" to set visible of process "FortiClient" to false
		display notification "Disconnected" with title "FortiClient VPN" sound name "Glass"
	else
		display notification "Disconnect failed" with title "FortiClient VPN" sound name "Basso"
		error "Still connected after ~30 s — the tunnel did not come down." number 6
	end if
end run
