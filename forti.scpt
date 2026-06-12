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
--    6  connection failed or timed out
--    7  already connected to a different profile
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

	try
		tell application "FortiClient" to activate
	on error
		error "FortiClient.app not found or failed to launch — is FortiClient installed?" number 8
	end try

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

			-- already connected? (the form is replaced by a Disconnect button)
			if my findElement(elems, "AXButton", "Disconnect") is not missing value then
				-- make sure it is the *requested* tunnel before claiming success
				set activeProfile to ""
				set vpnPopup to my findElement(elems, "AXPopUpButton", "VPN Name")
				if vpnPopup is not missing value then
					try
						set activeProfile to value of vpnPopup
					on error
						set activeProfile to "" -- popup exposes no value while connected; treat as unknown
					end try
				end if
				if (activeProfile is not "") and (activeProfile is not profileName) then
					error "Already connected to '" & activeProfile & "', not '" & profileName & "'. Disconnect first: osascript forti-disconnect.scpt" number 7
				end if
				set visible to false
				display notification "Already connected: " & profileName with title "FortiClient VPN" sound name "Glass"
				return
			end if

			-- select the requested profile in the "VPN Name" popup
			set vpnPopup to my findElement(elems, "AXPopUpButton", "VPN Name")
			if vpnPopup is missing value then
				error "Popup 'VPN Name' not found — the accessibility tree is probably not exposed. Run forti-debug.scpt and see the MANUAL.md debugging table." number 3
			end if
			click vpnPopup
			delay 0.4
			set profileSelected to false
			try
				click menu item profileName of vpnPopup
				set profileSelected to true
			on error
				-- close the popup menu we just opened, or it lingers over the
				-- window and confuses the next run's element search
				key code 53 -- Escape
			end try
			if not profileSelected then
				error "Profile '" & profileName & "' not found in the 'VPN Name' dropdown — the name must match the dropdown entry." number 4
			end if
			delay 0.8

			-- the web view may have re-rendered after the profile switch
			set elems to entire contents of window 1
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
		end tell
	end tell

	-- wait up to ~30 s for the button to flip to "Disconnect"
	set connected to false
	repeat 15 times
		delay 2
		tell application "System Events"
			tell process "FortiClient"
				set elems to entire contents of window 1
			end tell
		end tell
		if my findElement(elems, "AXButton", "Disconnect") is not missing value then
			set connected to true
			exit repeat
		end if
	end repeat

	if connected then
		tell application "System Events" to set visible of process "FortiClient" to false
		display notification "Connected: " & profileName with title "FortiClient VPN" sound name "Glass"
	else
		display notification "Connection failed: " & profileName with title "FortiClient VPN" sound name "Basso"
		error "Connection to '" & profileName & "' failed or timed out after ~30 s (slow gateway / 2FA prompt / wrong credentials)." number 6
	end if
end run
