#!/usr/bin/env bash
# Behavior tests for heavy. Usage: tests/run.sh [path/to/heavy]
# Prints PASS/FAIL per case and exits non-zero if any case fails. Uses only tools
# present on Linux, WSL and macOS, and runs on bash 3.2.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)/heavy}"
T="$(mktemp -d /tmp/heavytest.XXXXXX)"
export HEAVY_LOCK="$T/l" HEAVY_SLOTS=2
fail=0
ok() { echo "PASS $1"; }
ko() { echo "FAIL $1: $2"; fail=1; }
has_proc() { ps -A -o args= 2>/dev/null | grep -q "^$1"; }

echo "bash $BASH_VERSION | flock:$(command -v flock >/dev/null && echo y || echo n) perl:$(command -v perl >/dev/null && echo y || echo n) ionice:$(command -v ionice >/dev/null && echo y || echo n)"

# Two slots: A and B start together, C waits for one of them.
s=$(date +%s)
"$H" sh -c 'sleep 2' & a=$!
"$H" sh -c 'sleep 2' & b=$!
sleep 0.5
"$H" sh -c 'true' 2>"$T/c.err"
e=$(( $(date +%s) - s ))
wait $a $b
if grep -q queued "$T/c.err" && [ "$e" -ge 2 ]; then ok "2 slots, third waits (${e}s)"; else ko "slots" "e=$e $(cat "$T/c.err")"; fi

# Exit code passes through.
"$H" sh -c 'exit 7'; r=$?; [ $r -eq 7 ] && ok "exit code" || ko "exit code" "$r"

# stdin reaches the command.
out=$(echo input | "$H" cat); [ "$out" = input ] && ok "stdin" || ko "stdin" "$out"

# A nested heavy doesn't deadlock waiting on its own slot.
out=$(HEAVY_SLOTS=1 HEAVY_WAIT=3 "$H" "$H" echo nested 2>&1); [ "$out" = nested ] && ok "nested" || ko "nested" "$out"

# --timeout kills the command and its children, exit 124.
"$H" --timeout 1 sh -c 'sleep 33; true' 2>/dev/null; r=$?
sleep 0.5
if [ $r -eq 124 ] && ! has_proc 'sleep 33'; then ok "--timeout"; else ko "--timeout" "rc=$r"; fi

# --timeout not reached: real exit code, no delay from the watchdog.
s=$(date +%s); "$H" --timeout 30 sh -c 'exit 3'; r=$?; e=$(( $(date +%s) - s ))
[ $r -eq 3 ] && [ "$e" -lt 3 ] && ok "--timeout not reached" || ko "--timeout not reached" "rc=$r e=$e"

# HEAVY_WAIT gives up with exit 75.
HEAVY_SLOTS=1 "$H" sleep 3 & p=$!; sleep 0.5
HEAVY_SLOTS=1 HEAVY_WAIT=1 "$H" true 2>/dev/null; r=$?; wait $p
[ $r -eq 75 ] && ok "HEAVY_WAIT -> 75" || ko "HEAVY_WAIT" "rc=$r"

# A process left in the background doesn't keep holding the slot.
HEAVY_SLOTS=1 "$H" sh -c 'sleep 8 >/dev/null 2>&1 &'
HEAVY_SLOTS=1 HEAVY_WAIT=2 "$H" true 2>/dev/null; r=$?
[ $r -eq 0 ] && ok "background leftover frees the slot" || ko "background leftover" "rc=$r"

# SIGTERM to heavy reaches the command and its children.
"$H" sh -c 'sleep 34; true' & p=$!; sleep 0.5; kill -TERM $p; wait $p 2>/dev/null; sleep 0.5
has_proc 'sleep 34' && ko "TERM forwarding" "orphan left" || ok "TERM forwarding"

# Low priority. getpriority() reads the kernel's value; `ps -o nice=` differs
# between procps and BSD ps.
if command -v perl >/dev/null; then
  n=$("$H" perl -e 'print getpriority(0, 0)'); [ "$n" = 10 ] && ok "nice 10" || ko "nice" "$n"
fi

# --status names the holder.
HEAVY_SLOTS=1 "$H" sleep 2 & p=$!; sleep 0.5
HEAVY_SLOTS=1 "$H" --status | grep -q 'sleep 2' && ok "--status" || ko "--status" "$(HEAVY_SLOTS=1 "$H" --status)"
wait $p

pkill -f 'sleep 8' 2>/dev/null
rm -rf "$T"
exit $fail
