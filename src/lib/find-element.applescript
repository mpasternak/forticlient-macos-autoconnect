-- lib/find-element.applescript — recursive UI-tree lookup shared by the tools.

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
