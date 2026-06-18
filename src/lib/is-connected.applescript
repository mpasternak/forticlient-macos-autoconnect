-- lib/is-connected.applescript — the single "fully connected" criterion.
-- Depends on findElement (lib/find-element.applescript).

-- True when the index `idx` shows a fully-up tunnel: a Disconnect button *and*
-- a Duration status label. The Disconnect button alone only means a connect is
-- in progress (it doubles as a cancel then). Keeping this in one place means
-- forti.scpt and forti-status.scpt cannot drift on what "connected" means.
on isConnected(idx)
	return (my findElement(idx, "AXButton", "Disconnect") is not missing value) and (my findElement(idx, "AXStaticText", "Duration") is not missing value)
end isConnected
