#!/bin/bash
# forti-debug.sh — diagnostic dump of the FortiClient accessibility tree.
#
# Use this when forti.scpt fails with -1728 (element not found) or behaves
# unexpectedly. It enables AXManualAccessibility, dumps the UI tree and lists
# every interactive element the script could target.

set -u

echo "=== 1. Activating FortiClient and enabling accessibility tree ==="
osascript <<'EOF'
tell application "FortiClient" to activate
delay 1.5
tell application "System Events"
	tell process "FortiClient"
		set frontmost to true
		try
			set value of attribute "AXManualAccessibility" to true
		end try
		try
			set value of attribute "AXEnhancedUserInterface" to true
		end try
	end tell
end tell
EOF
sleep 1

echo
echo "=== 2. Windows of process FortiClient ==="
osascript -e 'tell application "System Events" to tell process "FortiClient" to get name of every window' \
	|| echo "!! Could not list windows — check Accessibility permission for your terminal."

echo
echo "=== 3. Interactive elements (role: name) ==="
osascript <<'EOF'
tell application "System Events"
	tell process "FortiClient"
		set out to ""
		set elems to entire contents of window 1
		repeat with e in elems
			try
				set r to role of e
				if r is in {"AXButton", "AXTextField", "AXPopUpButton", "AXCheckBox", "AXMenuItem"} then
					set n to ""
					try
						set n to name of e
					end try
					set out to out & r & ": \"" & n & "\"" & linefeed
				end if
			end try
		end repeat
		if out is "" then set out to "(none found — accessibility tree is probably not exposed; re-run this script or increase delays)"
		return out
	end tell
end tell
EOF

echo
echo "=== 4. Full UI tree of window 1 (verbose) ==="
osascript -e 'tell application "System Events" to tell process "FortiClient" to get entire contents of window 1'

echo
echo "=== 5. Tunnel interfaces currently up ==="
ifconfig | grep -E "^(utun|ipsec)" || echo "(none)"

echo
echo "=== 6. Keychain entries (service names starting with forti-vpn-) ==="
security dump-keychain 2>/dev/null | grep -o '"svce"<blob>="forti-vpn-[^"]*"' | sort -u \
	|| echo "(none found)"
