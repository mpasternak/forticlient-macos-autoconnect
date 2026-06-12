#!/bin/bash
# tests/manual-test.sh — interactive manual test suite for forti.scpt and
# forti-disconnect.scpt.
#
# The GUI tests drive the REAL FortiClient app and connect/disconnect REAL
# VPN tunnels — run this locally and attended, with FortiClient installed,
# both test profiles configured in its GUI, Keychain items present, and
# Accessibility permission granted to your terminal. Safe tests (no GUI)
# always run; each GUI test asks for confirmation and can be skipped.
#
# Usage:
#   tests/manual-test.sh                # full interactive suite
#   tests/manual-test.sh --safe-only    # only the GUI-free tests
#
# Profiles used by the GUI tests; override via environment:
#   FORTI_TEST_PROFILE_A=IHIT FORTI_TEST_PROFILE_B=IPIS tests/manual-test.sh

set -u

cd "$(dirname "$0")/.." || exit 1

PROFILE_A="${FORTI_TEST_PROFILE_A:-IHIT}"
PROFILE_B="${FORTI_TEST_PROFILE_B:-IPIS}"
SAFE_ONLY=0
[[ "${1:-}" == "--safe-only" ]] && SAFE_ONLY=1

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=""

# run_and_check <desc> <expected-exit> <expected-errnum|-> <cmd...>
# Runs <cmd...>, compares the exit status and — unless "-" — the trailing
# "(N)" error number on the last stderr line (the scripts' error contract).
run_and_check() {
    local desc="$1" want_exit="$2" want_err="$3"
    shift 3
    echo
    echo "-- $desc"
    echo "   \$ $*"
    local stderr_file rc errnum
    stderr_file="$(mktemp)"
    "$@" >/dev/null 2>"$stderr_file"
    rc=$?
    errnum="$(tail -n1 "$stderr_file" | grep -oE '\(-?[0-9]+\)$' | tr -d '()')"
    if [[ "$rc" -eq "$want_exit" && ( "$want_err" == "-" || "$errnum" == "$want_err" ) ]]; then
        echo "   PASS  exit=$rc${errnum:+ error=($errnum)}"
        PASS=$((PASS + 1))
    else
        echo "   FAIL  expected exit=$want_exit error=($want_err), got exit=$rc error=(${errnum:-none})"
        sed 's/^/   stderr> /' "$stderr_file"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS
  - $desc"
    fi
    rm -f "$stderr_file"
}

# gui_test <prompt> <desc> <expected-exit> <expected-errnum|-> <cmd...>
# Asks before running; "s" (or --safe-only) skips.
gui_test() {
    local prompt="$1"
    shift
    if [[ "$SAFE_ONLY" -eq 1 ]]; then
        echo
        echo "-- $1"
        echo "   SKIP  (--safe-only)"
        SKIP=$((SKIP + 1))
        return
    fi
    echo
    read -r -p ">> $prompt -- Enter to run, [s]kip: " ans
    if [[ "$ans" == [sS] ]]; then
        echo "   SKIP"
        SKIP=$((SKIP + 1))
        return
    fi
    run_and_check "$@"
}

echo "FortiClient manual test suite"
echo "Profiles: A=$PROFILE_A  B=$PROFILE_B  (override: FORTI_TEST_PROFILE_A/_B)"

if [[ "$SAFE_ONLY" -eq 0 ]]; then
    for p in "$PROFILE_A" "$PROFILE_B"; do
        if ! security find-generic-password -s "forti-vpn-$p" >/dev/null 2>&1; then
            echo "WARNING: no Keychain item 'forti-vpn-$p' -- connect tests for '$p' will fail" >&2
        fi
    done
    if [[ ! -d /Applications/FortiClient.app ]]; then
        echo "WARNING: /Applications/FortiClient.app not found -- GUI tests will fail" >&2
    fi
    echo
    echo "The GUI tests connect and disconnect REAL VPN tunnels. Close anything"
    echo "that depends on your current VPN before continuing."
fi

echo
echo "=== Safe tests (no GUI) ==="

run_and_check "forti.scpt compiles" \
    0 - osacompile -o /tmp/forti-test-syntax.scpt forti.scpt
run_and_check "forti-disconnect.scpt compiles" \
    0 - osacompile -o /tmp/forti-disconnect-test-syntax.scpt forti-disconnect.scpt
run_and_check "usage error without arguments (64)" \
    1 64 osascript forti.scpt
run_and_check "missing Keychain item (2)" \
    1 2 osascript forti.scpt NoSuchProfile-manual-test

echo
echo "=== GUI tests ==="

gui_test "Ensure a clean start: disconnect whatever is connected (~5-35 s)" \
    "disconnect from any state exits 0" \
    0 - osascript forti-disconnect.scpt

gui_test "Connect to $PROFILE_A from disconnected (~10-40 s)" \
    "connect $PROFILE_A" \
    0 - osascript forti.scpt "$PROFILE_A"

gui_test "Run the same connect again -- must report 'already connected' quickly" \
    "already connected to $PROFILE_A" \
    0 - osascript forti.scpt "$PROFILE_A"

gui_test "Request $PROFILE_B while connected to $PROFILE_A -- must auto-disconnect and switch (~30-80 s)" \
    "auto-switch $PROFILE_A -> $PROFILE_B" \
    0 - osascript forti.scpt "$PROFILE_B"

gui_test "Switch back to $PROFILE_A the same way (~30-80 s)" \
    "auto-switch $PROFILE_B -> $PROFILE_A" \
    0 - osascript forti.scpt "$PROFILE_A"

gui_test "Disconnect the active tunnel (~5-35 s)" \
    "disconnect after connect" \
    0 - osascript forti-disconnect.scpt

gui_test "Disconnect again while nothing is connected -- still exit 0" \
    "disconnect when not connected" \
    0 - osascript forti-disconnect.scpt

echo
echo "=== Summary ==="
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed tests:$FAILED_TESTS"
    exit 1
fi
