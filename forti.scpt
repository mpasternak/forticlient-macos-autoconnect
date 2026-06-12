#!/usr/bin/osascript
-- forti.scpt — FortiClient IPsec VPN auto-connect for macOS
--
-- Usage:   osascript forti.scpt <ProfileName> [username]
--
-- Credentials are read from the login Keychain item with service name
-- "forti-vpn-<ProfileName>": the account attribute is the VPN username,
-- the password is the VPN password. See README.md.
--
-- Exit status: 0 on success (connected, or already connected), 1 on any
-- failure. osascript maps every script error to exit status 1, so the
-- specific failure is carried in the stderr message and its error number:
--   64  usage error (no profile argument)
--    2  Keychain item missing, unreadable, or without an account attribute
--    3  FortiClient window did not appear, or "VPN Name" popup not found
--       (accessibility tree not exposed?)
--    4  profile not present in the "VPN Name" dropdown
--    5  expected UI element not found (Username/Password field, Connect button)
--    6  connection, or auto-disconnect during a profile switch, timed out
--    7  an externally started connection completed on a different profile
--    8  FortiClient is not installed or failed to launch

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

-- Console progress. Step lines use `log` (osascript sends them to stderr).
-- The overwriting bar must go straight to /dev/tty: `do shell script`
-- DISCARDS stderr on success (TN2065), so "printf ... >&2" outputs nothing.
-- /dev/tty also keeps redirected stdout/stderr clean; with no controlling
-- terminal (launchd, cron) the printf fails and the bar is skipped.
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

on run argv
	if (count of argv) is 0 then
		error "Usage: osascript forti.scpt <ProfileName> [username]" number 64
	end if
	set profileName to item 1 of argv

	-- username from the Keychain item's account attribute, password from its
	-- value. The awk pipe masks a failing `security` (the pipeline's status is
	-- awk's), so the password fetch doubles as the existence check — it fails
	-- properly when the item is missing.
	try
		set vpnPass to do shell script "security find-generic-password -s forti-vpn-" & quoted form of profileName & " -w"
	on error
		error "No Keychain item with service name 'forti-vpn-" & profileName & "' in the login keychain (see README section 1). The service name is case-sensitive." number 2
	end try
	if (count of argv) > 1 then
		-- explicit override from the command line; no need to parse the account
		set vpnUser to item 2 of argv
	else
		set vpnUser to do shell script "security find-generic-password -s forti-vpn-" & quoted form of profileName & " | awk -F'\"' '/\"acct\"/{print $4}'"
		if vpnUser is "" then
			error "Keychain item 'forti-vpn-" & profileName & "' has no readable account attribute (it was created without -a, or the username is non-ASCII and stored as hex). Re-add the item with -a <username>, or pass the username as the second argument." number 2
		end if
	end if

	log "* credentials for '" & profileName & "' loaded from the Keychain"
	log "* activating FortiClient"
	try
		tell application "FortiClient" to activate
	on error
		error "FortiClient.app not found or failed to launch — is FortiClient installed?" number 8
	end try

	set connectInProgress to false
	tell application "System Events"
		tell process "FortiClient"
			set frontmost to true
			-- a cold launch can take a few seconds to show the window
			set windowReady to false
			repeat 20 times
				if (count of windows) > 0 then
					set windowReady to true
					exit repeat
				end if
				delay 0.5
			end repeat
			if not windowReady then
				error "No FortiClient window appeared within 10 s. Run forti-debug.scpt and see the MANUAL.md debugging table." number 3
			end if
			delay 1 -- let the web view render before touching the tree
			-- FortiClient's UI is an embedded Chromium web view; its accessibility
			-- tree is hidden until this attribute is set. Resets on app restart,
			-- so it must run on every invocation.
			try
				set value of attribute "AXManualAccessibility" to true
			end try
			delay 0.5

			set elems to entire contents of window 1

			-- A Disconnect button alone only means a connection attempt is at
			-- least in progress (it doubles as a cancel while connecting); the
			-- status labels (Duration / Bytes ...) appear once the tunnel is up.
			set disconnectBtn to my findElement(elems, "AXButton", "Disconnect")
			if disconnectBtn is not missing value then
				if my findElement(elems, "AXStaticText", "Duration") is not missing value then
					-- fully connected — is it the *requested* tunnel?
					set activeProfile to my activeProfileName(elems)
					if (activeProfile is "") or (activeProfile is profileName) then
						log "* already connected to '" & profileName & "'"
						set visible to false
						display notification "Already connected: " & profileName with title "FortiClient VPN" sound name "Glass"
						return
					end if
					-- a different profile is up: disconnect it automatically and
					-- fall through to the normal connect flow below
					log "* connected to '" & activeProfile & "' — disconnecting first"
					display notification "Switching: " & activeProfile & " → " & profileName with title "FortiClient VPN"
					click disconnectBtn
					set formBack to false
					my progressBar("disconnecting", 0, 30)
					repeat with i from 1 to 15
						delay 2
						my progressBar("disconnecting", i * 2, 30)
						set elems to entire contents of window 1
						if my findElement(elems, "AXButton", "Connect") is not missing value then
							set formBack to true
							exit repeat
						end if
					end repeat
					if not formBack then
						my endProgress("disconnecting: timed out")
						error "Auto-disconnect from '" & activeProfile & "' did not complete within ~30 s; not connecting to '" & profileName & "'." number 6
					end if
					my endProgress("disconnecting: done")
				else
					-- a connect started outside this script is still running —
					-- don't touch the form, just wait for the outcome below
					log "* a connection attempt is already in progress — waiting for it"
					set connectInProgress to true
				end if
			end if

			if not connectInProgress then
				-- select the requested profile in the "VPN Name" popup
				set vpnPopup to my findElement(elems, "AXPopUpButton", "VPN Name")
				if vpnPopup is missing value then
					error "Popup 'VPN Name' not found — the accessibility tree is probably not exposed. Run forti-debug.scpt and see the MANUAL.md debugging table." number 3
				end if
				-- leave the dropdown alone when it already shows the requested
				-- profile: clicking the currently-selected menu item fails in the
				-- web view (field-observed as a spurious error 4)
				set currentProfile to ""
				try
					set currentProfile to value of vpnPopup
				on error
					set currentProfile to "" -- value unreadable; select via the dropdown
				end try
				if currentProfile is not profileName then
					click vpnPopup
					delay 0.4
					-- Chromium opens the <select> as a native menu. Proper System
					-- Events addressing goes through "menu 1"; some builds accept
					-- the bare form. Errors here are expected — success is verified
					-- by reading the popup's value below, not by the click.
					try
						click menu item profileName of menu 1 of vpnPopup
					on error
						try
							click menu item profileName of vpnPopup
						end try
					end try
					delay 0.4
					set newProfile to ""
					try
						set newProfile to value of vpnPopup -- unreadable mid-render: caught below as mismatch
					end try
					if newProfile is not profileName then
						-- the menu is still open (both clicks failed): native menus
						-- select by typed prefix, Enter confirms
						keystroke profileName
						delay 0.2
						key code 36 -- Enter
						delay 0.4
						try
							set newProfile to value of vpnPopup -- unreadable: caught below as mismatch
						end try
					end if
					if newProfile is not profileName then
						-- close whatever is still open, or it lingers over the
						-- window and confuses the next run's element search
						key code 53 -- Escape
						error "Profile '" & profileName & "' not found in the 'VPN Name' dropdown — the name must match the dropdown entry. Run forti-debug.scpt and see the MANUAL.md debugging table." number 4
					end if
					delay 0.8
					-- the web view may have re-rendered after the profile switch
					set elems to entire contents of window 1
				end if
				log "* profile '" & profileName & "' selected"

				set userFieldFound to false
				set passFieldFound to false
				repeat with e in elems
					try
						if role of e is "AXTextField" then
							if name of e is "Username" then
								set value of e to vpnUser
								set userFieldFound to true
							else if name of e is "Password" then
								set value of e to vpnPass
								set passFieldFound to true
							end if
						end if
					end try
				end repeat
				if not userFieldFound then
					error "Text field 'Username' not found — run forti-debug.scpt to inspect the real element names." number 5
				end if
				if not passFieldFound then
					error "Text field 'Password' not found — run forti-debug.scpt to inspect the real element names." number 5
				end if

				set connectBtn to my findElement(elems, "AXButton", "Connect")
				if connectBtn is missing value then
					error "Button 'Connect' not found — run forti-debug.scpt to inspect the real element names." number 5
				end if
				click connectBtn
				log "* credentials filled, Connect clicked"
			end if
		end tell
	end tell

	-- Wait up to ~30 s for the tunnel to come up. The Disconnect button alone
	-- is not enough — it is already shown (as a cancel) while still connecting,
	-- and FortiClient re-shows the window itself when the connection completes;
	-- the status labels appear only in the truly connected view.
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
		if (my findElement(elems, "AXButton", "Disconnect") is not missing value) and (my findElement(elems, "AXStaticText", "Duration") is not missing value) then
			set connected to true
			exit repeat
		end if
	end repeat
	if connected then
		my endProgress("connecting: tunnel is up")
	else
		my endProgress("connecting: timed out")
	end if

	if connected and connectInProgress then
		-- the attempt we waited for was started outside this script — make
		-- sure it ended up on the requested profile
		set activeProfile to my activeProfileName(elems)
		if (activeProfile is not "") and (activeProfile is not profileName) then
			error "A connection to '" & activeProfile & "' (not '" & profileName & "') was already in progress and completed. Disconnect first: osascript forti-disconnect.scpt" number 7
		end if
	end if

	if connected then
		log "Connected: " & profileName
		tell application "System Events" to set visible of process "FortiClient" to false
		display notification "Connected: " & profileName with title "FortiClient VPN" sound name "Glass"
	else
		display notification "Connection failed: " & profileName with title "FortiClient VPN" sound name "Basso"
		error "Connection to '" & profileName & "' failed or timed out after ~30 s (slow gateway / 2FA prompt / wrong credentials)." number 6
	end if
end run
