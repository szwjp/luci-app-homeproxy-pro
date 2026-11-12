#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# The runtime watchdog (runtime/watchdog.sh, scripts/watchdog.sh).
#
# What it exists for is the black hole the start-path release cannot cover: the
# intercept layer is installed, sing-box is not answering, and nothing takes the
# layer down - so the LAN loses TCP and DNS until someone notices.  The
# properties worth pinning are the ones whose failure is quiet:
#
#   * It must NOT act on a blip.  procd's own respawn takes about 5 seconds; a
#     watchdog that releases the layer on one bad sample turns every ordinary
#     restart into an outage, and re-arms into another.
#   * It must act on a real failure, exactly once, and not on every sample
#     after it.
#   * It must come back.  A layer that is released and never re-armed is a
#     proxy that silently stopped proxying.  That includes the layer a failed
#     START released - the path service_started() cannot undo after a respawn.
#   * It must not flap.  A failure right after a re-arm lengthens the hold-off;
#     a long healthy stretch resets it.
#   * "Cannot probe here" is not a failure (no nslookup on a stripped image).
#   * The VPS is not its business: nothing in the sample reads a node.
#
# The decision (hp_wd_step) is a pure function over a few counters, so it is
# driven directly with a synthetic clock.  The loop (hp_wd_run) is driven with
# the sample, the clock and the init script's two commands stubbed, so the whole
# release -> hold-off -> re-arm cycle runs without procd, nft or a router.
#
# The last block is wiring: the init script exposes the two commands the daemon
# calls, loads the config in them (hp_net_teardown reads it), registers the
# daemon only when the option allows, and keeps its first lines intact (rpcd's
# `rc list` reads only those).
#
# Usage: sh tests/runtime/test_watchdog.sh <repo-root>

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
RUNTIME="$ROOT/root/etc/homeproxy/scripts/runtime"
INIT="$ROOT/root/etc/init.d/homeproxy"
DAEMON="$ROOT/root/etc/homeproxy/scripts/watchdog.sh"
SERVICE="$RUNTIME/service.sh"
CONFIG="$ROOT/root/etc/config/homeproxy"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hp-watchdog.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILED=0
CHECKS=0
FAILURES=0

expect() {
	# expect <name> <actual> <expected>
	CHECKS=$((CHECKS + 1))
	if [ "$2" = "$3" ]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (expected '$3', got '$2')"
		FAILED=1
		FAILURES=$((FAILURES + 1))
	fi
}

for f in "$RUNTIME/health.sh" "$RUNTIME/watchdog.sh" "$DAEMON" "$INIT"; do
	if [ ! -f "$f" ]; then
		echo "FAIL: $f is missing"
		exit 1
	fi
done

# log() is the init script's; the libraries only call it.
LOGFILE="$WORK/log"
: > "$LOGFILE"
log() { echo "$*" >> "$LOGFILE"; }

# shellcheck source=/dev/null
. "$RUNTIME/health.sh"
# shellcheck source=/dev/null
. "$RUNTIME/watchdog.sh"

# ----------------------------------------------------------------------
# 1. value handling
# ----------------------------------------------------------------------
expect "bound: a value inside the range is kept" "$(hp_wd_bound 30 5 300 10)" "30"
expect "bound: below the minimum is raised (a 0s loop would spin)" "$(hp_wd_bound 0 5 300 10)" "5"
expect "bound: above the maximum is lowered" "$(hp_wd_bound 99999 5 300 10)" "300"
expect "bound: not a number falls back to the default" "$(hp_wd_bound abc 5 300 10)" "10"
expect "bound: empty falls back to the default" "$(hp_wd_bound '' 5 300 10)" "10"
expect "bound: a negative sign is not a number" "$(hp_wd_bound -3 5 300 10)" "10"
expect "bound: a decimal is not a number" "$(hp_wd_bound 1.5 5 300 10)" "10"
expect "bound: shell metacharacters are not a number" "$(hp_wd_bound '1;rm' 5 300 10)" "10"

expect "defaults: the probe names are domestic (never example.com)" \
	"$(echo "$HP_WD_PROBE_NAMES" | grep -c 'example\.com')" "0"
expect "defaults: sampling every 10s, 4 failures to act" "$HP_WD_INTERVAL/$HP_WD_FAIL_LIMIT" "10/4"

# ----------------------------------------------------------------------
# 2. DNS probe verdict combination
# ----------------------------------------------------------------------
# hp_probe_dns is health.sh's; stub it with a per-name verdict.
PROBE_BAD_NAMES=""
PROBE_UNKNOWN=0
hp_probe_dns() {
	[ "$PROBE_UNKNOWN" = 1 ] && return 2
	case " $PROBE_BAD_NAMES " in
	*" $2 "*) return 1 ;;
	esac
	return 0
}

PROBE_BAD_NAMES=""
hp_wd_probe_dns 5333 a.cn b.cn
expect "probe: every name resolves -> 0" "$?" "0"

PROBE_BAD_NAMES="a.cn"
hp_wd_probe_dns 5333 a.cn b.cn
expect "probe: one name failing but another resolving -> 0" "$?" "0"

PROBE_BAD_NAMES="a.cn b.cn"
hp_wd_probe_dns 5333 a.cn b.cn
expect "probe: no name resolves -> 1" "$?" "1"

PROBE_UNKNOWN=1
hp_wd_probe_dns 5333 a.cn b.cn
expect "probe: cannot probe here -> 2" "$?" "2"
PROBE_UNKNOWN=0

# ----------------------------------------------------------------------
# 3. one health sample
# ----------------------------------------------------------------------
SVC_OK=0
hp_service_healthy() { return "$SVC_OK"; }
hp_config_ports() { echo "5333 5330"; }

SVC_OK=0; PROBE_BAD_NAMES=""
hp_wd_sample "$WORK/c.json" 5333 a.cn
expect "sample: instance up and DNS answering -> healthy" "$?" "0"

SVC_OK=1; PROBE_BAD_NAMES=""
hp_wd_sample "$WORK/c.json" 5333 a.cn
expect "sample: instance down -> unhealthy" "$?" "1"

SVC_OK=0; PROBE_BAD_NAMES="a.cn"
hp_wd_sample "$WORK/c.json" 5333 a.cn
expect "sample: instance up but DNS silent (a hung sing-box) -> unhealthy" "$?" "1"

SVC_OK=0; PROBE_UNKNOWN=1
hp_wd_sample "$WORK/c.json" 5333 a.cn
expect "sample: cannot probe DNS here is not a failure" "$?" "0"
PROBE_UNKNOWN=0

# ----------------------------------------------------------------------
# 4. the state machine, on a synthetic clock
# ----------------------------------------------------------------------
HP_WD_FAIL_LIMIT=4
HP_WD_RECOVER_STABLE=3
HP_WD_HOLD_MIN=60
HP_WD_HOLD_MAX=600
HP_WD_STABLE_SECS=120

# step <released> <healthy> <now>  ->  the action ("" if none)
step() {
	hp_wd_step "$1" "$2" "$3"
	printf '%s' "$HP_WD_ACTION"
}

# armed: a blip shorter than the limit never acts
hp_wd_reset
a=""
for t in 10 20 30; do a="$a$(step 0 1 $t)"; done
# command substitution above ran in subshells; redo without them for the counters
hp_wd_reset
for t in 10 20 30; do hp_wd_step 0 1 "$t"; a="$a$HP_WD_ACTION"; done
expect "armed: 3 failures in a row (limit 4) do not release" "$a" ""
hp_wd_step 0 0 40
expect "armed: a healthy sample clears the failure run" "$HP_WD_FAILS" "0"
for t in 50 60 70; do hp_wd_step 0 1 "$t"; done
expect "armed: the run starts over after a healthy sample (3 more is still no release)" "$HP_WD_ACTION" ""

# armed: the limit-th failure releases, once
hp_wd_reset
for t in 10 20 30; do hp_wd_step 0 1 "$t"; done
hp_wd_step 0 1 40
expect "armed: the 4th failure in a row releases" "$HP_WD_ACTION" "release"
expect "armed: the release sets the hold-off from now" "$HP_WD_HOLD_UNTIL" "100"
hp_wd_step 0 1 50
expect "armed: the failure run restarts after a release (no instant second release)" "$HP_WD_ACTION" ""

# released: needs a stable run AND the hold-off
hp_wd_reset
HP_WD_HOLD_UNTIL=100
hp_wd_step 1 0 60; hp_wd_step 1 0 70
expect "released: 2 healthy samples are not yet stable" "$HP_WD_ACTION" ""
hp_wd_step 1 0 80
expect "released: stable but inside the hold-off does not re-arm" "$HP_WD_ACTION" ""
hp_wd_step 1 0 100
expect "released: stable and the hold-off elapsed re-arms" "$HP_WD_ACTION" "rearm"

hp_wd_reset
HP_WD_HOLD_UNTIL=0
hp_wd_step 1 0 10; hp_wd_step 1 1 20; hp_wd_step 1 0 30; hp_wd_step 1 0 40
expect "released: an unhealthy sample resets the stable run" "$HP_WD_ACTION" ""
hp_wd_step 1 0 50
expect "released: ...and 3 healthy in a row after it re-arm" "$HP_WD_ACTION" "rearm"

# a layer released by a failed START has no hold-off
hp_wd_reset
hp_wd_step 1 0 5; hp_wd_step 1 0 15; hp_wd_step 1 0 25
expect "released by a failed start: re-arms as soon as the client is stably up" "$HP_WD_ACTION" "rearm"

# flapping: a failure right after a re-arm lengthens the hold-off
hp_wd_reset
HP_WD_HOLD_UNTIL=0
hp_wd_step 1 0 1000; hp_wd_step 1 0 1010; hp_wd_step 1 0 1020
expect "flap: re-armed at 1020" "$HP_WD_ACTION/$HP_WD_REARMED_AT" "rearm/1020"
for t in 1030 1040 1050 1060; do hp_wd_step 0 1 "$t"; done
expect "flap: failing 40s after the re-arm releases again" "$HP_WD_ACTION" "release"
expect "flap: ...with a doubled back-off (60 -> 120)" "$HP_WD_BACKOFF" "120"
expect "flap: ...so the next re-arm is held off 120s" "$HP_WD_HOLD_UNTIL" "1180"

# the back-off never exceeds the maximum
HP_WD_BACKOFF=400
HP_WD_REARMED_AT=2000
for t in 2010 2020 2030 2040; do hp_wd_step 0 1 "$t"; done
expect "flap: the back-off is capped at the maximum (400 -> 600, not 800)" "$HP_WD_BACKOFF" "600"

# a long healthy stretch resets the back-off
hp_wd_reset
HP_WD_BACKOFF=240
HP_WD_REARMED_AT=3000
hp_wd_step 0 0 3060
expect "stable: inside the window the back-off is kept" "$HP_WD_BACKOFF" "240"
hp_wd_step 0 0 3130
expect "stable: healthy past the window resets the back-off" "$HP_WD_BACKOFF" "60"
expect "stable: ...and forgets the re-arm" "$HP_WD_REARMED_AT" "0"

# a failure long after a re-arm is not a flap
hp_wd_reset
HP_WD_REARMED_AT=4000
HP_WD_BACKOFF=60
for t in 5000 5010 5020 5030; do hp_wd_step 0 1 "$t"; done
expect "not a flap: a failure long after a re-arm keeps the short hold-off" "$HP_WD_BACKOFF" "60"

# ----------------------------------------------------------------------
# 5. the loop, end to end with stubs
# ----------------------------------------------------------------------
RUN="$WORK/run"
mkdir -p "$RUN"
CALLS="$WORK/calls"

FAKE_NOW=0
hp_wd_now() { echo "$FAKE_NOW"; }
# the loop sleeps; advance the synthetic clock instead
sleep() { FAKE_NOW=$((FAKE_NOW + ${1:-0})); }

# hp_config_port_for_tag is health.sh's and reads a file; the loop only needs a number
hp_config_port_for_tag() { echo 5333; }

# the init script's two commands, as the daemon calls them
REARM_FAILS=0
fake_init() {
	echo "$1" >> "$CALLS"
	case "$1" in
	release_intercept) : > "$RUN/intercept-released"; return 0 ;;
	rearm_intercept)
		[ "$REARM_FAILS" = 1 ] && return 1
		rm -f "$RUN/intercept-released"
		return 0
		;;
	esac
}
HP_WD_INIT=fake_init

# the sample, scripted: a space-separated list of 0/1, consumed one per loop,
# the last value repeating once the list runs out
SEQ=""
hp_wd_sample() {
	set -- $SEQ
	if [ "$#" -gt 1 ]; then
		SEQ="$(echo "$SEQ" | cut -d' ' -f2-)"
	fi
	return "$1"
}

run_loop() {
	# run_loop <loops> <sequence> [released-at-start]
	: > "$CALLS"
	: > "$LOGFILE"
	rm -f "$RUN/intercept-released"
	[ -n "$3" ] && : > "$RUN/intercept-released"
	FAKE_NOW=1000
	SEQ="$2"
	HP_WD_GRACE=0
	HP_WD_INTERVAL=10
	HP_WD_MAX_LOOPS="$1"
	hp_wd_run "$RUN" "$WORK/c.json" a.cn
}

calls() { tr '\n' ' ' < "$CALLS" | sed 's/ $//'; }

# a blip: 3 failed samples then healthy, never reaches the limit of 4
run_loop 12 "1 1 1 0"
expect "loop: a blip shorter than the limit makes no call at all" "$(calls)" ""

# a real failure: down for good
run_loop 10 "1"
expect "loop: a sustained failure releases exactly once" "$(calls)" "release_intercept"
expect "loop: ...and says so in the service log" \
	"$(grep -c 'releasing the intercept layer' "$LOGFILE")" "1"

# failure, then recovery after the hold-off
run_loop 40 "1 1 1 1 0"
expect "loop: failure then recovery releases, then re-arms" "$(calls)" "release_intercept rearm_intercept"
expect "loop: the marker is gone after the re-arm" "$([ -f "$RUN/intercept-released" ] && echo present || echo absent)" "absent"

# the hold-off is honoured: recover almost at once, but the re-arm waits
run_loop 8 "1 1 1 1 0"
expect "loop: healthy again inside the hold-off does not re-arm yet" "$(calls)" "release_intercept"

# a layer a failed start released comes back once the client is stably up
run_loop 8 "0" 1
expect "loop: a start-released layer is re-armed once healthy" "$(calls)" "rearm_intercept"

# a re-arm that fails halfway is answered by releasing again, and does not spin
REARM_FAILS=1
run_loop 10 "0" 1
expect "loop: a failed re-arm releases again" "$(calls | sed 's/ .*//')" "rearm_intercept"
expect "loop: ...and the layer is down afterwards" \
	"$([ -f "$RUN/intercept-released" ] && echo present || echo absent)" "present"
expect "loop: ...without hammering: at most 2 re-arm attempts in 10 loops" \
	"$([ "$(grep -c rearm_intercept "$CALLS")" -le 2 ] && echo yes || echo no)" "yes"
REARM_FAILS=0

# it samples through the loop, not just once: the call count scales with failures
run_loop 40 "1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 1 1 1"
expect "loop: two separate outages are two releases" \
	"$(grep -c release_intercept "$CALLS")" "2"

unset -f sleep hp_wd_now hp_wd_sample hp_probe_dns hp_service_healthy hp_config_ports hp_config_port_for_tag

# ----------------------------------------------------------------------
# 6. wiring
# ----------------------------------------------------------------------
init_body() {
	# init_body <function> : print that function's body from the init script
	awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "$INIT"
}

expect "init: release_intercept is declared an extra command" \
	"$(grep -c '^EXTRA_COMMANDS=.*release_intercept' "$INIT")" "1"
expect "init: rearm_intercept is declared an extra command" \
	"$(grep -c '^EXTRA_COMMANDS=.*rearm_intercept' "$INIT")" "1"
expect "init: release_intercept loads the config first (hp_net_teardown reads it)" \
	"$(init_body release_intercept | grep -n 'config_load\|hp_release_intercept' | sed 's/:.*//; s/$//' | tr '\n' ' ')" "2 3 "
expect "init: rearm_intercept reads the proxy and routing mode before re-arming" \
	"$(init_body rearm_intercept | grep -c 'config_get proxy_mode\|config_get routing_mode')" "2"
expect "init: rearm_intercept calls hp_rearm_intercept with both modes" \
	"$(init_body rearm_intercept | grep -c 'hp_rearm_intercept "\$proxy_mode" "\$routing_mode"')" "1"

# rpcd's `rc list` reads only the head of the file for these three
head11="$(sed -n '1,11p' "$INIT")"
for key in 'USE_PROCD=1' 'START=' 'STOP='; do
	expect "init: '$key' is still within the first 11 lines" \
		"$(echo "$head11" | grep -c "^$key")" "1"
done

expect "init: the daemon is registered through hp_procd_watchdog_instance" \
	"$(grep -c 'hp_procd_watchdog_instance "\$HP_DIR"' "$INIT")" "1"
expect "init: ...only when the watchdog option is on (default on)" \
	"$(grep -c 'config_get_bool watchdog "config" "watchdog" "1"' "$INIT")" "1"
expect "init: ...and only inside the client branch" \
	"$(awk '/hp_procd_client_instance "\$PROG"/ {c=1} c && /hp_procd_watchdog_instance/ {print "after-client"; exit}' "$INIT")" "after-client"

body="$(awk '/^hp_procd_watchdog_instance\(\) \{/ {p=1} p {print} p && /^\}/ {exit}' "$SERVICE")"
expect "service: the daemon runs through /bin/sh, not by path (needs no execute bit)" \
	"$(echo "$body" | grep -c 'procd_set_param command /bin/sh "\$hp_dir/scripts/watchdog.sh"')" "1"
expect "service: the daemon is respawned without a retry limit" \
	"$(echo "$body" | grep -c 'procd_set_param respawn 3600 5 0')" "1"
expect "service: the daemon is its own named instance" \
	"$(echo "$body" | grep -c 'procd_open_instance "watchdog"')" "1"
expect "service: the daemon's command line cannot match the client's health pattern" \
	"$(echo "$body" | grep -c 'sing-box run')" "0"

expect "daemon: sources the health library and the watchdog library" \
	"$(grep -c '^\. "\$HP_DIR/scripts/runtime/\(health\|watchdog\)\.sh"' "$DAEMON")" "2"
expect "daemon: defines log() before the libraries need it" \
	"$([ "$(grep -n '^log()' "$DAEMON" | head -1 | cut -d: -f1)" -lt "$(grep -n '^\. ' "$DAEMON" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" "yes"
expect "daemon: clamps the interval it reads from UCI" \
	"$(grep -c 'hp_wd_bound "\$(hp_wd_uci watchdog_interval)"' "$DAEMON")" "1"
expect "daemon: clamps the failure limit it reads from UCI" \
	"$(grep -c 'hp_wd_bound "\$(hp_wd_uci watchdog_fail_limit)"' "$DAEMON")" "1"

expect "the library never reads a node (it does not judge the VPS)" \
	"$(grep -v '^[[:space:]]*#' "$RUNTIME/watchdog.sh" | grep -c 'uci .*node\|@node\|outbound\|server_port')" "0"
expect "the library has no foreign probe name baked in" \
	"$(grep -v '^[[:space:]]*#' "$RUNTIME/watchdog.sh" | grep -c 'google\|example\.com\|cloudflare\|8\.8\.8\.8')" "0"

for opt in "watchdog '1'" "watchdog_interval '10'" "watchdog_fail_limit '4'"; do
	expect "config: default $opt" "$(grep -c "^	option $opt\$" "$CONFIG")" "1"
done
expect "config: the default probe names are domestic" \
	"$(grep -c "option watchdog_probe_names 'www.baidu.com www.qq.com'" "$CONFIG")" "1"

# shell syntax of everything this adds
for f in "$RUNTIME/watchdog.sh" "$DAEMON" "$INIT" "$SERVICE"; do
	if sh -n "$f" 2> "/dev/null"; then r=ok; else r=bad; fi
	expect "syntax: $(basename "$f")" "$r" "ok"
done

printf '%d checks, %d failures\n' "$CHECKS" "$FAILURES"
[ "$FAILED" = 0 ] && echo "WATCHDOG TESTS PASSED"
exit "$FAILED"
