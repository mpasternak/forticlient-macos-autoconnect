-- lib/active-profile.applescript — read the connected profile name.

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
