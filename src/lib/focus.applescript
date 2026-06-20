-- lib/focus.applescript — momentary foreground for keystroke-only actions.
--
-- Almost everything the tools do (read the tree, set field values, click
-- elements) is an Accessibility action that works on a background window. The
-- exceptions both involve the native "VPN Name" dropdown: clicking its menu
-- item and the `keystroke` fallback only act on the frontmost app. These two
-- handlers bracket that selection — focusFortiClient brings FortiClient to the
-- front and reports which app was frontmost before, restoreFront hands that
-- focus straight back — so the app is on top only for the profile switch, then
-- drops to the background again. Used only by forti.scpt — to bracket the
-- profile-switch selection (focusFortiClient/restoreFront) and to keep the
-- window down when FortiClient self-activates on connect (pushBack).
-- forti-disconnect needs none of this.

-- Make FortiClient frontmost and return the name of the app that was frontmost
-- beforehand, so restoreFront can give focus back to it.
on focusFortiClient()
	tell application "System Events"
		set prevApp to name of first process whose frontmost is true
		set frontmost of process "FortiClient" to true
	end tell
	return prevApp
end focusFortiClient

-- Return focus to the app that held it before focusFortiClient. A failure here
-- is non-fatal (the connect already happened), so it is logged, not swallowed
-- silently, per the no-silent-error rule.
on restoreFront(prevApp)
	if prevApp is "FortiClient" then return -- it was already frontmost; nothing to restore
	try
		tell application "System Events" to set frontmost of process prevApp to true
	on error errMsg
		log "* could not restore focus to '" & prevApp & "' (" & errMsg & ")"
	end try
end restoreFront

-- Keep FortiClient out of the user's way during the connect poll. FortiClient
-- brings its OWN window to the front when the tunnel comes up; we hide that
-- window once the poll confirms the connection, but that confirmation is a
-- coarse (~2 s) check, so without this the window would sit on top until then.
-- Called every ~0.3 s, pushBack shoves the captured caller app straight back on
-- top the moment FortiClient self-activates, so the pop lasts a tick at most. A
-- no-op when nothing was captured, or when FortiClient is not the one in front.
on pushBack(callerApp)
	if callerApp is "" or callerApp is "FortiClient" then return
	tell application "System Events"
		try
			if frontmost of process "FortiClient" then set frontmost of process callerApp to true
		on error
			-- expected/transient: mid-connect the FortiClient process or callerApp
			-- can briefly be unaddressable (the same window flicker safeWindowContents
			-- tolerates). Skipping one push-back is harmless — the next tick retries.
			-- Deliberately not logged: at ~0.3 s cadence it would only spam.
		end try
	end tell
end pushBack
