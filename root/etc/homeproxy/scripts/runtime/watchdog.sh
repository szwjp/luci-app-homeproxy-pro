# SPDX-License-Identifier: GPL-2.0-only
#
# Runtime watchdog for homeproxy.
#
# What it closes.  The intercept layer (the nft redirect/tproxy chains and the
# dnsmasq snippets that make sing-box dnsmasq's ONLY upstream) is installed by
# start_service and taken down again only when a *start* or a *reload* cannot
# prove the client came up (hp_release_intercept).  Once the service is
# running, nothing watches it:
#
#   * sing-box crashes, procd respawns it after its 5s timeout, and for that
#     window the LAN's TCP is refused and its DNS goes nowhere;
#   * procd gives up after its retry budget (3600s/5s/5 by default), and the
#     intercept layer keeps pointing the LAN at a listener that no longer
#     exists - a permanent black hole until somebody notices;
#   * sing-box hangs without exiting, which procd cannot see at all;
#   * a release that happened on the start path is only undone by
#     service_started(), which does not run again when procd respawns the
#     instance - the service then reports "running" while nothing is proxied.
#
# What it does.  It is a fail-OPEN watchdog: when the client stops being
# healthy for long enough it takes the intercept layer down with the same
# hp_release_intercept() the start path uses (the instance itself keeps being
# supervised by procd), so the LAN falls back to direct routing and the ISP
# resolver instead of black-holing.  When the client has been healthy again for
# a stretch it puts the layer back with hp_rearm_intercept().  Both go through
# the init script's release_intercept / rearm_intercept commands, so there is
# one implementation of each and the intercept-released marker stays the single
# source of truth for "is the layer down".
#
# What it deliberately does NOT do.
#
#   * It does not judge the VPS.  An unreachable node leaves sing-box alive and
#     routing, and direct traffic is unaffected; taking the whole proxy down for
#     that would turn a partial outage into a total one.
#   * It does not probe a foreign name.  Under most routing modes a foreign
#     name is resolved THROUGH the proxy, so a dead node would make a healthy
#     sing-box look broken.  The probes resolve domestic names, which every
#     mode sends to the direct resolver.
#   * It does not act on "cannot probe here" (no nslookup, no netstat owner
#     column): there is nothing to conclude from a missing tool.
#   * It does not flap.  A failure shortly after a re-arm doubles the hold-off
#     before the next re-arm (hold-min .. hold-max), so a half-broken node costs
#     a couple of seconds of DNS per cycle, not a cycle per interval.
#
# The decision is a pure function of (is the layer down, was this sample
# healthy, what time is it) over a handful of counters, so it is tested off
# target without procd or a router (tests/runtime/test_watchdog.sh).
#
# Needs runtime/health.sh sourced first (hp_service_healthy, hp_config_ports,
# hp_config_port_for_tag, hp_probe_dns) and a log() function.

# Seconds between samples, and how many failed samples in a row make a failure.
# 4 x 10s = 40s comfortably outlasts procd's own 5s respawn, so an ordinary
# restart never trips it.
: "${HP_WD_INTERVAL:=10}"
: "${HP_WD_FAIL_LIMIT:=4}"

# Healthy samples in a row before the layer is put back.
: "${HP_WD_RECOVER_STABLE:=3}"

# Seconds to wait after the daemon starts before the first sample counts.  The
# daemon is registered together with the client, and service_started()'s own
# health gate may spend up to HP_HEALTH_BUDGET (30s) proving it; sampling during
# that window would race the gate.
: "${HP_WD_GRACE:=45}"

# Hold-off before a re-arm after the watchdog released the layer, doubling on
# every flap up to the maximum.  A re-arm that then stays healthy for
# HP_WD_STABLE_SECS resets it.
: "${HP_WD_HOLD_MIN:=60}"
: "${HP_WD_HOLD_MAX:=600}"
: "${HP_WD_STABLE_SECS:=120}"

# Domestic names for the DNS probe.  Any one resolving is enough.
: "${HP_WD_PROBE_NAMES:=www.baidu.com www.qq.com}"

# The init script whose release_intercept / rearm_intercept commands do the work.
: "${HP_WD_INIT:=/etc/init.d/homeproxy}"

# Counters (see hp_wd_reset).
HP_WD_FAILS=0
HP_WD_GOOD=0
HP_WD_HOLD_UNTIL=0
HP_WD_BACKOFF="$HP_WD_HOLD_MIN"
HP_WD_REARMED_AT=0

# What hp_wd_step decided: "release", "rearm" or "".  A variable rather than
# stdout: the caller reads it in the same shell, because a command substitution
# would run the step in a subshell and lose every counter it just updated.
HP_WD_ACTION=""

# hp_wd_is_uint <value>
hp_wd_is_uint() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

# hp_wd_bound <value> <min> <max> <default>
# Print <value> clamped to [min, max]; the default when it is not a number.
# The values come from UCI, which anyone can put anything in, and a zero
# interval would turn the loop into a busy spin.
hp_wd_bound() {
	local v="$1" min="$2" max="$3" def="$4"

	hp_wd_is_uint "$v" || v="$def"
	[ "$v" -lt "$min" ] && v="$min"
	[ "$v" -gt "$max" ] && v="$max"
	printf '%s\n' "$v"
}

# hp_wd_reset
# Forget everything: a fresh daemon starts armed-and-unsuspicious.
hp_wd_reset() {
	HP_WD_FAILS=0
	HP_WD_GOOD=0
	HP_WD_HOLD_UNTIL=0
	HP_WD_BACKOFF="$HP_WD_HOLD_MIN"
	HP_WD_REARMED_AT=0
	HP_WD_ACTION=""
}

# hp_wd_now
# Seconds on a clock that only goes forward; wall-clock time can jump when NTP
# syncs, which would corrupt the hold-off arithmetic.
hp_wd_now() {
	local up
	up="$(cut -d. -f1 /proc/uptime 2>"/dev/null")"
	hp_wd_is_uint "$up" || up=0
	printf '%s\n' "$up"
}

# hp_wd_probe_dns <dns-port> <name>...
# 0 at least one name resolved through the DNS inbound, 1 none did, 2 cannot
# probe here.  hp_probe_dns says "cannot probe" for a missing nslookup or an
# empty port, and that must not be counted as a failure.
hp_wd_probe_dns() {
	local port="$1" name failed=0

	shift
	for name in "$@"; do
		hp_probe_dns "$port" "$name"
		case "$?" in
		0) return 0 ;;
		1) failed=1 ;;
		esac
	done

	[ "$failed" -eq 1 ] && return 1
	return 2
}

# hp_wd_sample <config-file> <dns-port> <name>...
# One health sample of the client: 0 healthy, 1 not.
#
# Healthy is: procd says sing-box-c is running with the exact config, the
# declared listeners are owned by sing-box (hp_service_healthy), and the DNS
# inbound answers a domestic name.  "Cannot probe" on the DNS side counts as
# healthy - an unknown is not a verdict.
hp_wd_sample() {
	local config="$1" dns_port="$2" ports

	shift 2
	ports="$(hp_config_ports "$config")"

	# shellcheck disable=SC2086  # $ports is a deliberate word list
	hp_service_healthy "sing-box-c" "$config" $ports || return 1

	hp_wd_probe_dns "$dns_port" "$@"
	case "$?" in
	1) return 1 ;;
	esac

	return 0
}

# hp_wd_step <released:0|1> <healthy:0|1> <now>
# Advance the state machine by one sample and leave the decision in
# HP_WD_ACTION.
#
#   armed (released=0)    a healthy sample clears the failure count; a failed one
#                         adds to it, and HP_WD_FAIL_LIMIT in a row releases.
#   released (released=1) HP_WD_RECOVER_STABLE healthy samples in a row, and the
#                         hold-off elapsed, re-arm.  A layer released by a failed
#                         START has no hold-off (HOLD_UNTIL is 0), so it comes
#                         back as soon as the client is stably up - which is the
#                         path service_started() cannot cover after a respawn.
hp_wd_step() {
	local released="$1" healthy="$2" now="$3"

	HP_WD_ACTION=""

	if [ "$released" != "1" ]; then
		HP_WD_GOOD=0

		if [ "$healthy" = "0" ]; then
			HP_WD_FAILS=0
			# Healthy for long enough since the last re-arm: the flapping is
			# over, so the next release starts from the short hold-off again.
			if [ "$HP_WD_REARMED_AT" -gt 0 ] \
				&& [ $((now - HP_WD_REARMED_AT)) -ge "$HP_WD_STABLE_SECS" ]; then
				HP_WD_BACKOFF="$HP_WD_HOLD_MIN"
				HP_WD_REARMED_AT=0
			fi
			return 0
		fi

		HP_WD_FAILS=$((HP_WD_FAILS + 1))
		[ "$HP_WD_FAILS" -ge "$HP_WD_FAIL_LIMIT" ] || return 0

		HP_WD_FAILS=0
		# A failure soon after a re-arm is a flap: wait longer before the
		# next one.  A failure after a long healthy stretch is not.
		if [ "$HP_WD_REARMED_AT" -gt 0 ] \
			&& [ $((now - HP_WD_REARMED_AT)) -lt "$HP_WD_STABLE_SECS" ]; then
			HP_WD_BACKOFF=$((HP_WD_BACKOFF * 2))
			[ "$HP_WD_BACKOFF" -gt "$HP_WD_HOLD_MAX" ] && HP_WD_BACKOFF="$HP_WD_HOLD_MAX"
		fi
		HP_WD_HOLD_UNTIL=$((now + HP_WD_BACKOFF))
		HP_WD_ACTION="release"
		return 0
	fi

	HP_WD_FAILS=0

	if [ "$healthy" = "0" ]; then
		HP_WD_GOOD=$((HP_WD_GOOD + 1))
	else
		HP_WD_GOOD=0
	fi

	if [ "$HP_WD_GOOD" -ge "$HP_WD_RECOVER_STABLE" ] && [ "$now" -ge "$HP_WD_HOLD_UNTIL" ]; then
		HP_WD_GOOD=0
		HP_WD_REARMED_AT="$now"
		HP_WD_ACTION="rearm"
	fi

	return 0
}

# hp_wd_do_release <reason>
hp_wd_do_release() {
	log "Watchdog: client unhealthy ($1); releasing the intercept layer so the LAN falls back to direct routing."
	"$HP_WD_INIT" release_intercept > "/dev/null" 2>&1 \
		|| log "Watchdog: release_intercept failed."
}

# hp_wd_do_rearm
# A re-arm that fails halfway must not leave a half-installed layer behind
# with the marker already removed (hp_rearm_intercept deletes it first), so a
# failure is answered by releasing again.
hp_wd_do_rearm() {
	log "Watchdog: client healthy again; reinstalling the intercept layer."
	if ! "$HP_WD_INIT" rearm_intercept > "/dev/null" 2>&1; then
		log "Watchdog: the intercept layer could not be reinstalled; releasing it again."
		"$HP_WD_INIT" release_intercept > "/dev/null" 2>&1
		HP_WD_HOLD_UNTIL=$(($(hp_wd_now) + HP_WD_BACKOFF))
	fi
}

# hp_wd_released <run-dir>
# 0 when the intercept layer is down (by this daemon or by a failed start).
hp_wd_released() {
	[ -f "$1/intercept-released" ]
}

# hp_wd_run <run-dir> <config-file>
# The daemon loop.  HP_WD_MAX_LOOPS (0 = forever) exists for the tests.
hp_wd_run() {
	local run_dir="$1" config="$2" loops=0 dns_port released healthy now

	# shellcheck disable=SC2086  # the names are a deliberate word list
	set -- $HP_WD_PROBE_NAMES

	hp_wd_reset
	log "Watchdog started: sampling every ${HP_WD_INTERVAL}s, releasing after ${HP_WD_FAIL_LIMIT} failed samples."
	sleep "$HP_WD_GRACE"

	while :; do
		if [ "${HP_WD_MAX_LOOPS:-0}" -gt 0 ]; then
			loops=$((loops + 1))
			[ "$loops" -gt "$HP_WD_MAX_LOOPS" ] && break
		fi

		sleep "$HP_WD_INTERVAL"

		# Re-read every time: a rollback can swap the live file for the
		# known-good copy, which may bind a different DNS port.
		dns_port="$(hp_config_port_for_tag "$config" 'dns-in')"

		if hp_wd_sample "$config" "$dns_port" "$@"; then
			healthy=0
		else
			healthy=1
		fi

		released=0
		hp_wd_released "$run_dir" && released=1
		now="$(hp_wd_now)"

		hp_wd_step "$released" "$healthy" "$now"

		case "$HP_WD_ACTION" in
		release) hp_wd_do_release "failed ${HP_WD_FAIL_LIMIT} samples in a row" ;;
		rearm) hp_wd_do_rearm ;;
		esac
	done
}
