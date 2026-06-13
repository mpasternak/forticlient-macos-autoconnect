-- lib/notify.applescript — best-effort macOS notification.

-- Post a notification, but NEVER let it fail the operation: notifications are
-- a non-essential side effect that can be unavailable (disabled, no
-- permission, or no GUI session under launchd/cron). Pass "" as soundName for
-- a silent notification. The error is logged, not swallowed silently.
on notifyOptional(theMessage, soundName)
	try
		if soundName is "" then
			display notification theMessage with title "FortiClient VPN"
		else
			display notification theMessage with title "FortiClient VPN" sound name soundName
		end if
	on error errMsg
		log "* notification skipped (" & errMsg & ")"
	end try
end notifyOptional
