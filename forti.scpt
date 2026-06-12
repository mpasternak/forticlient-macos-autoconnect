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
--    2  Keychain item missing or unreadable
--    3  "VPN Name" popup not found (accessibility tree not exposed?)
--    4  profile not present in the "VPN Name" dropdown
--    5  expected UI element not found (Username/Password field, Connect button)
--    6  connection failed or timed out

on run argv
	if (count of argv) is 0 then
		error "Usage: osascript forti.scpt <ProfileName> [username]" number 64
	end if
	set profileName to item 1 of argv

	-- username from the Keychain item's account attribute, password from its
	-- value. The awk pipe masks a failing `security` (the pipeline's status is
	-- awk's), so fetch the password first — it fails properly when the item is
	-- missing.
	try
		set vpnPass to do shell script "security find-generic-password -s forti-vpn-" & quoted form of profileName & " -w"
		set vpnUser to do shell script "security find-generic-password -s forti-vpn-" & quoted form of profileName & " | awk -F'\"' '/\"acct\"/{print $4}'"
	on error
		error "No Keychain item with service name 'forti-vpn-" & profileName & "' in the login keychain (see README section 1). The service name is case-sensitive." number 2
	end try
	-- optional explicit override from the command line
	if (count of argv) > 1 then set vpnUser to item 2 of argv

	tell application "FortiClient" to activate
	delay 1.5

	tell application "System Events"
		tell process "FortiClient"
			set frontmost to true
			-- FortiClient's UI is an embedded Chromium web view; its accessibility
			-- tree is hidden until this attribute is set. Resets on app restart,
			-- so it must run on every invocation.
			try
				set value of attribute "AXManualAccessibility" to true
			end try
			delay 0.5

			set elems to entire contents of window 1

			-- already connected? (the form is replaced by a Disconnect button)
			repeat with e in elems
				try
					if (role of e is "AXButton") and (name of e is "Disconnect") then
						set visible to false
						display notification "Already connected" with title "FortiClient VPN" sound name "Glass"
						return
					end if
				end try
			end repeat

			-- select the requested profile in the "VPN Name" popup
			set popupFound to false
			set profileSelected to false
			repeat with e in elems
				try
					if (role of e is "AXPopUpButton") and (name of e is "VPN Name") then
						set popupFound to true
						click e
						delay 0.4
						click menu item profileName of e
						set profileSelected to true
						exit repeat
					end if
				end try
			end repeat
			if not popupFound then
				error "Popup 'VPN Name' not found — the accessibility tree is probably not exposed. Run forti-debug.scpt and see the MANUAL.md debugging table." number 3
			end if
			if not profileSelected then
				error "Profile '" & profileName & "' not found in the 'VPN Name' dropdown (the match is case-sensitive)." number 4
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

			set connectClicked to false
			repeat with e in elems
				try
					if (role of e is "AXButton") and (name of e is "Connect") then
						click e
						set connectClicked to true
						exit repeat
					end if
				end try
			end repeat
			if not connectClicked then
				error "Button 'Connect' not found — run forti-debug.scpt to inspect the real element names." number 5
			end if
		end tell
	end tell

	-- wait up to ~30 s for the button to flip to "Disconnect"
	set connected to false
	repeat 15 times
		delay 2
		tell application "System Events"
			tell process "FortiClient"
				set elems to entire contents of window 1
				repeat with e in elems
					try
						if (role of e is "AXButton") and (name of e is "Disconnect") then
							set connected to true
							exit repeat
						end if
					end try
				end repeat
			end tell
		end tell
		if connected then exit repeat
	end repeat

	if connected then
		tell application "System Events" to set visible of process "FortiClient" to false
		display notification "Connected: " & profileName with title "FortiClient VPN" sound name "Glass"
	else
		display notification "Connection failed: " & profileName with title "FortiClient VPN" sound name "Basso"
		error "Connection to '" & profileName & "' failed or timed out after ~30 s (slow gateway / 2FA prompt / wrong credentials)." number 6
	end if
end run
