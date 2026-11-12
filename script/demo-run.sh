#!/usr/bin/env bash
# Plays the demo story on a fresh demo deployment (CRON=100 SILENCE=300 GRACE=240 DEMO_TOKEN=1): wait for the
# warning, check in (the warning is cancelled), stay silent until the release, then distribute the demo token.
# Each step is logged with the time and the vault chain's block, and so is every stage change of the watch, which
# shows how long a callback took to arrive; the balances and debts before and after show what it all cost.
# Needs: KEY_FILE (the owner's key, read only when sending), CHECKIN, VAULT, WATCH, DEMO, and RPC (one chain) or
# VAULT_RPC + WATCH_RPC (the vault's chain, Reactive). Optional: VAULT_PROXY (the vault chain's callback proxy,
# default Reactive's), SEND_FLAGS (extra cast send options, e.g. fees), LOG, CAST.
set -u
: "${KEY_FILE:?}" "${CHECKIN:?}" "${VAULT:?}" "${WATCH:?}" "${DEMO:?}"
VAULT_RPC=${VAULT_RPC:-${RPC:?}}
WATCH_RPC=${WATCH_RPC:-$RPC}
SYS=0x8888888888888888888888888888888888888888
VAULT_PROXY=${VAULT_PROXY:-$SYS}
LOG=${LOG:-/dev/null}
CAST=${CAST:-cast}
NAMES=(Armed Warning Released Refused)
WATCH_SEEN=""

qv() { $CAST call "$@" --rpc-url "$VAULT_RPC" 2>/dev/null | awk '{print $1}'; }
qw() { $CAST call "$@" --rpc-url "$WATCH_RPC" 2>/dev/null | awk '{print $1}'; }
log() { printf '[%s] block %s | %s\n' "$(date '+%F %T')" "$($CAST block-number --rpc-url "$VAULT_RPC" 2>/dev/null)" "$*" | tee -a "$LOG"; }
stage() { qv "$VAULT" "stage()(uint8)"; }
money() {
    log "  watch balance $($CAST balance "$WATCH" --rpc-url "$WATCH_RPC") debt $(qw $SYS "debt(address)(uint256)" "$WATCH") reserves $(qw $SYS "reserves(address)(uint256)" "$WATCH")"
    log "  vault balance $($CAST balance "$VAULT" --rpc-url "$VAULT_RPC") debt $(qv "$VAULT_PROXY" "debt(address)(uint256)" "$VAULT") reserves $(qv "$VAULT_PROXY" "reserves(address)(uint256)" "$VAULT")"
    log "  watch: lastTick $(qw "$WATCH" "lastTick()(uint40)") tickEvery $(qw "$WATCH" "tickEvery()(uint40)") tickFee $(qw "$WATCH" "tickFee()(uint256)") fundedUntil $(qw "$WATCH" "fundedUntil()(uint256)")"
}
# $1 = the vault stages to wait for (a regex), $2 = timeout in seconds
wait_stage() {
    local t=0 s w
    while :; do
        w=$(qw "$WATCH" "stage()(uint8)")
        if [ -n "$w" ] && [ "$w" != "$WATCH_SEEN" ]; then log "watch stage = ${NAMES[$w]}"; WATCH_SEEN=$w; fi
        s=$(stage)
        if [[ "$s" =~ ^($1)$ ]]; then log "vault stage = ${NAMES[$s]}"; return 0; fi
        if ((t >= $2)); then log "TIMEOUT waiting for vault stage $1 (now ${s:-?})"; return 1; fi
        sleep 15
        ((t += 15))
    done
}
send() {
    # shellcheck disable=SC2086 # SEND_FLAGS is a list of options on purpose
    $CAST send "$@" ${SEND_FLAGS:-} --private-key "$(cat "$KEY_FILE")" --rpc-url "$VAULT_RPC" 2>&1 |
        awk '/^(status|transactionHash|blockNumber) /{printf "%s=%s ", $1, $2}'
}

log "start, vault stage = ${NAMES[$(stage)]}"
money
wait_stage 1 1200 || exit 1
sleep 30 # leave the warning on screen a moment
log "owner checks in: $(send "$CHECKIN" "checkIn()")"
wait_stage '0|2|3' 900 || exit 1
[ "$(stage)" = 0 ] || { log "expected the cancel, stop"; exit 1; }
log "warning cancelled; now silent until the release"
wait_stage 1 1200 || exit 1
wait_stage '2|3' 1200 || exit 1
[ "$(stage)" = 2 ] || { log "release refused, stop"; money; exit 1; }
log "distribute DEMO: $(send "$VAULT" "distribute(address)" "$DEMO")"
for h in $($CAST call "$VAULT" "heirs()((address,uint256)[])" --rpc-url "$VAULT_RPC" | grep -o -E "0x[0-9a-fA-F]{40}"); do
    log "heir $h DEMO $(qv "$DEMO" "balanceOf(address)(uint256)" "$h")"
done
log "owner DEMO $(qv "$DEMO" "balanceOf(address)(uint256)" "$(qv "$VAULT" "owner()(address)")")"
money
log "done"
