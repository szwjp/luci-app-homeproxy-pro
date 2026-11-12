#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# The watchdog daemon.  Registered by the init script as the procd instance
# "watchdog" next to sing-box-c, and started with `/bin/sh <this file>` rather
# than by path: a file added through a web UI or an archive does not always
# keep its execute bit, and a service that silently fails to start for that
# reason is the failure mode this exists to prevent.
#
# It lives and dies with the service - `stop` and `reload` remove every
# instance - so there is no "the operator stopped it on purpose" case to
# distinguish from a crash.  The behaviour is in runtime/watchdog.sh.
#
# Settings (UCI homeproxy.config.*, all optional):
#   watchdog             1 (default) / 0.  Read by the init script: when 0 this
#                        daemon is not registered at all.
#   watchdog_interval    seconds between samples          (default 10, 5..300)
#   watchdog_fail_limit  failed samples in a row to act   (default 4, 2..30)
#   watchdog_probe_names space-separated DOMESTIC names for the DNS probe
#
# Progress goes to the service log, next to the init script's own lines, so it
# shows up in the LuCI log viewer: grep for [WATCHDOG].

HP_DIR="${HP_DIR:-/etc/homeproxy}"
RUN_DIR="${RUN_DIR:-/var/run/homeproxy}"
LOG_PATH="${LOG_PATH:-$RUN_DIR/homeproxy.log}"
CONF="${CONF:-homeproxy}"

log() {
	[ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>"/dev/null"
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") [WATCHDOG] $*" >> "$LOG_PATH"
}

# shellcheck source=/dev/null
. "$HP_DIR/scripts/runtime/health.sh" || exit 1
# shellcheck source=/dev/null
. "$HP_DIR/scripts/runtime/watchdog.sh" || exit 1

hp_wd_uci() {
	uci -q get "$CONF.config.$1" 2>"/dev/null"
}

HP_WD_INTERVAL="$(hp_wd_bound "$(hp_wd_uci watchdog_interval)" 5 300 10)"
HP_WD_FAIL_LIMIT="$(hp_wd_bound "$(hp_wd_uci watchdog_fail_limit)" 2 30 4)"

_names="$(hp_wd_uci watchdog_probe_names)"
[ -n "$_names" ] && HP_WD_PROBE_NAMES="$_names"

export HP_WD_INTERVAL HP_WD_FAIL_LIMIT HP_WD_PROBE_NAMES

hp_wd_run "$RUN_DIR" "$RUN_DIR/sing-box-c.json"
