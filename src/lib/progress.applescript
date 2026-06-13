-- lib/progress.applescript — console progress shared by the tools.
-- Step lines use `log` (osascript sends them to stderr). The overwriting bar
-- must go straight to /dev/tty: `do shell script` DISCARDS stderr on success
-- (TN2065), so "printf ... >&2" outputs nothing. /dev/tty also keeps
-- redirected stdout/stderr clean; with no controlling terminal (launchd,
-- cron) the printf fails and the bar is skipped.
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
