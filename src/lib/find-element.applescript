-- lib/find-element.applescript — UI-tree indexing + lookup shared by the tools.
--
-- Reading `role`/`name` off a System Events element is one Apple Event that
-- re-resolves a deeply-nested Chromium accessibility specifier (~17 ms each),
-- whereas fetching `entire contents of window 1` is cheap (~40 ms). Walking the
-- live tree once per lookup therefore cost ~1 s a pass, and the connect flow ran
-- several passes (isConnected alone is two). buildIndex pays that traversal
-- ONCE, capturing every element's reference plus its role and (only for the
-- roles we ever look up) its name into parallel lists; findElement then matches
-- in memory with ZERO Apple Events. Callers pass the index record everywhere the
-- raw `entire contents` list used to flow.

-- One traversal of `elems` (an `entire contents` reference list) into an index
-- record of parallel lists in document order: {elemRefs, elemRoles, elemNames}.
-- `name` is read only for the roles any lookup cares about — groups/images are
-- never matched by name, so skipping them roughly halves the Apple Events.
on buildIndex(elems)
	set rolesOfInterest to {"AXTextField", "AXButton", "AXPopUpButton", "AXStaticText"}
	set roleList to {}
	set nameList to {}
	tell application "System Events"
		repeat with e in elems
			set thisRole to ""
			-- bare try: probing an element that lacks a role attribute is not an
			-- error condition, it just leaves this slot's role blank (unmatched).
			try
				set thisRole to (role of e)
			end try
			set end of roleList to thisRole
			set thisName to ""
			if rolesOfInterest contains thisRole then
				try
					set thisName to (name of e)
				end try
			end if
			set end of nameList to thisName
		end repeat
	end tell
	return {elemRefs:elems, elemRoles:roleList, elemNames:nameList}
end buildIndex

-- The empty index — returned by safeWindowContents when window 1 momentarily
-- vanishes, so lookups degrade to `missing value` instead of crashing a poll.
on emptyIndex()
	return {elemRefs:{}, elemRoles:{}, elemNames:{}}
end emptyIndex

-- First element of the index with the given role and name, or `missing value`.
-- Pure in-memory list scan (no Apple Events); returns the live element reference
-- so the caller can click it or set its value.
on findElement(idx, theRole, theName)
	set roleList to elemRoles of idx
	set nameList to elemNames of idx
	repeat with i from 1 to count of roleList
		if (item i of roleList is theRole) and (item i of nameList is theName) then
			return item i of (elemRefs of idx)
		end if
	end repeat
	return missing value
end findElement
