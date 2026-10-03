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

# A PATH with everything except pgrep, so heavy takes its ps fallback.
nopgrep_path() {
  local d dir f b
  d="$(mktemp -d "$T/np.XXXXXX")"
  for dir in $(printf '%s' "$PATH" | tr ':' ' '); do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      b="${f##*/}"
      [ "$b" = pgrep ] && continue
      [ -e "$d/$b" ] || ln -s "$f" "$d/$b" 2>/dev/null
    done
  done
  ln -sf "$(command -v bash)" "$d/bash" 2>/dev/null
  printf '%s' "$d"
}

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

# Without pgrep, the ps fallback still stops the whole tree (no orphan).
np="$(nopgrep_path)"
PATH="$np" "$H" sh -c 'sleep 35; true' & p=$!; sleep 0.5
kill -TERM $p; wait $p 2>/dev/null; sleep 0.5
has_proc 'sleep 35' && ko "TERM without pgrep" "orphan left" || ok "TERM without pgrep"

# Low priority: niceness 10 above the caller's (nice is relative; GitHub's macOS
# runners start at -10). getpriority() reads the kernel's value, where the
# output of `ps -o nice=` differs between procps and BSD ps.
if command -v perl >/dev/null; then
  base=$(perl -e 'print getpriority(0, 0)')
  want=$(( base + 10 > 19 ? 19 : base + 10 ))
  n=$("$H" perl -e 'print getpriority(0, 0)')
  [ "$n" = "$want" ] && ok "nice +10 ($base -> $n)" || ko "nice" "base=$base got=$n want=$want"
fi

# --status names the holder.
HEAVY_SLOTS=1 "$H" sleep 2 & p=$!; sleep 0.5
HEAVY_SLOTS=1 "$H" --status | grep -q 'sleep 2' && ok "--status" || ko "--status" "$(HEAVY_SLOTS=1 "$H" --status)"
wait $p

# --help prints the header and nothing from the code below it.
h=$("$H" --help 2>&1)
case "$h" in
  *"set -u"*|*"Real path of this script"*) ko "--help" "leaked code";;
  *"machine-wide queue"*) ok "--help";;
  *) ko "--help" "no header";;
esac

# A non-numeric --timeout is rejected, not turned into an instant timeout.
"$H" --timeout abc true 2>/dev/null; r=$?
[ $r -eq 2 ] && ok "--timeout rejects non-numeric" || ko "--timeout invalid" "rc=$r"

# Bad HEAVY_SLOTS/HEAVY_WAIT fall back instead of crashing or hanging.
HEAVY_SLOTS=abc "$H" sh -c 'exit 0' 2>/dev/null; r=$?
[ $r -eq 0 ] && ok "HEAVY_SLOTS invalid falls back" || ko "HEAVY_SLOTS invalid" "rc=$r"
HEAVY_WAIT=abc "$H" sh -c 'exit 0' 2>/dev/null; r=$?
[ $r -eq 0 ] && ok "HEAVY_WAIT invalid falls back" || ko "HEAVY_WAIT invalid" "rc=$r"

# An unreachable lock runs the command unqueued rather than spinning.
out=$(HEAVY_LOCK="$T/nope/l" HEAVY_WAIT=3 "$H" echo ran 2>/dev/null); r=$?
[ "$out" = ran ] && [ $r -eq 0 ] && ok "unreachable lock runs without queue" || ko "unreachable lock" "rc=$r out=$out"

pkill -f 'sleep 8' 2>/dev/null
rm -rf "$T"
exit $fail
