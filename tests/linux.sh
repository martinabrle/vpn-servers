#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/bootstrap.sh
source /validation/scripts/bootstrap.sh
WORK=$(mktemp -d)
trap cleanup EXIT
export VPN_HOST=vpn-test.denmarkeast.cloudapp.azure.com
STATE_DIR="$WORK/state"
generate_state "$STATE_DIR"
render_wireguard
render_ikev2
render_firewall eth0
nft --check --file "$WORK/nftables.conf"
nft --file "$WORK/nftables.conf"
wg-quick strip "$WORK/wg0.conf" > "$WORK/wg-stripped.conf"
ip link add wg-test type wireguard
wg setconf wg-test "$WORK/wg-stripped.conf"
ip link set wg-test up
for device in {1..20}; do
  printf -v number '%02d' "$device"
  wg-quick strip "$WORK/wireguard-${number}.conf" |
    sed 's/^Endpoint = .*/Endpoint = 127.0.0.1:51820/' > "$WORK/client.conf"
  ip link add "wgc${device}" type wireguard
  wg setconf "wgc${device}" "$WORK/client.conf"
  ip link set "wgc${device}" up
done
for ((attempt=0; attempt<30; attempt++)); do
  wg show wg-test latest-handshakes > "$WORK/handshakes"
  if awk '$2 > 0 {count++} END {exit count != 20}' "$WORK/handshakes"; then break; fi
  sleep 1
done
awk '$2 > 0 {count++} END {exit count != 20}' "$WORK/handshakes"
wg show wg-test
install -d /etc/swanctl/private /etc/swanctl/x509 /etc/swanctl/x509ca
install -m 600 "$STATE_DIR/server.key" /etc/swanctl/private/server.key
install -m 644 "$STATE_DIR/server.crt" /etc/swanctl/x509/server.crt
install -m 644 "$STATE_DIR/ca.crt" /etc/swanctl/x509ca/ca.crt
install -m 600 "$WORK/swanctl.conf" /etc/swanctl/swanctl.conf
/usr/sbin/charon-systemd > "$WORK/charon.log" 2>&1 &
charon_pid=$!
trap 'kill "$charon_pid"; cleanup' EXIT
for ((attempt=0; attempt<20; attempt++)); do
  if [[ -S /var/run/charon.vici ]]; then break; fi
  sleep 1
done
if ! swanctl --load-all; then
  cat "$WORK/charon.log" >&2
  exit 1
fi
swanctl --list-conns | grep -q '^ikev2:'
printf 'Linux nftables, 20 distinct WireGuard peer handshakes, and strongSwan credential/configuration loading passed.\n'
if [[ ${SHARED_PROFILE_SERVER:-0} == 1 ]]; then
  ip address add 198.18.0.1/32 dev lo
  cp -r "$STATE_DIR" /shared/state
  touch /shared/ready
  wait "$charon_pid"
fi
