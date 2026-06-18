-- lib/active-profile.applescript — read the connected profile name.

-- In the *connected* view the form is gone and the active profile is shown as
-- the static text that follows the "VPN Name" label static text in document
-- order. The index (see buildIndex) preserves that order, so this walks the
-- in-memory role/name lists — no Apple Events. Returns "" when undeterminable.
on activeProfileName(idx)
	set roleList to elemRoles of idx
	set nameList to elemNames of idx
	set seenLabel to false
	repeat with i from 1 to count of roleList
		if item i of roleList is "AXStaticText" then
			if seenLabel then
				return item i of nameList
			else if item i of nameList is "VPN Name" then
				set seenLabel to true
			end if
		end if
	end repeat
	return ""
end activeProfileName
