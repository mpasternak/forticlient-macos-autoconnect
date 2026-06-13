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
--    3  FortiClient window did not appear, or neither "Disconnect" nor
--       "Connect" button found (accessibility tree not exposed?)
--    6  still connected after ~30 s

--#include lib/find-element.applescript
--#include lib/progress.applescript
--#include lib/notify.applescript
--#include lib/window.applescript

on run argv
	-- If FortiClient is not running, no tunnel can be up (same assumption as
	-- forti-status.scpt). Bail out early rather than launching the app — or
	-- triggering the "Choose Application" dialog when it is not installed —
	-- just to tear down a connection that does not exist.
	tell application "System Events"
		if not (exists process "FortiClient") then
			log "* FortiClient is not running — nothing to disconnect"
			my notifyOptional("Not connected — nothing to disconnect", "Glass")
			return
		end if
	end tell

	log "* activating FortiClient"
	tell application "FortiClient" to activate
	tell application "System Events" to tell process "FortiClient" to set frontmost to true
	-- a cold launch can take a few seconds to show the window
	if not my waitForWindow() then
		error "No FortiClient window appeared within 10 s. Run forti-debug.scpt and see MANUAL.md." number 3
	end if

	tell application "System Events"
		tell process "FortiClient"
			-- Same Chromium web-view workaround as in forti.scpt; resets on app
			-- restart, so it must run on every invocation.
			try
				set value of attribute "AXManualAccessibility" to true
			on error errMsg
				log "* warning: could not set AXManualAccessibility (" & errMsg & ") — accessibility tree may be unavailable"
			end try
			delay 0.5
			set elems to entire contents of window 1
		end tell
	end tell

	set disconnectBtn to my findElement(elems, "AXButton", "Disconnect")
	if disconnectBtn is missing value then
		if my findElement(elems, "AXButton", "Connect") is not missing value then
			-- the connect form is showing, so no tunnel is up
			log "* not connected — nothing to disconnect"
			tell application "System Events" to set visible of process "FortiClient" to false
			my notifyOptional("Not connected — nothing to disconnect", "Glass")
			return
		end if
		error "Neither 'Disconnect' nor 'Connect' button found — the accessibility tree is probably not exposed. Run forti-debug.scpt and see MANUAL.md." number 3
	end if
	tell application "System Events" to tell process "FortiClient" to click disconnectBtn
	log "* Disconnect clicked"

	-- wait up to ~30 s for the button to flip back to "Connect"
	set disconnected to false
	my progressBar("disconnecting", 0, 30)
	repeat with i from 1 to 15
		delay 2
		my progressBar("disconnecting", i * 2, 30)
		if my findElement(my safeWindowContents(), "AXButton", "Connect") is not missing value then
			set disconnected to true
			exit repeat
		end if
	end repeat

	if disconnected then
		my endProgress("disconnecting: done")
		log "Disconnected"
		tell application "System Events" to set visible of process "FortiClient" to false
		my notifyOptional("Disconnected", "Glass")
	else
		my endProgress("disconnecting: timed out")
		my notifyOptional("Disconnect failed", "Basso")
		error "Still connected after ~30 s — the tunnel did not come down." number 6
	end if
end run
