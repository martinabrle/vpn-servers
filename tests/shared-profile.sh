#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
PREFIX="vpn-shared-${GITHUB_RUN_ID:-$$}"
WORK=$(mktemp -d)
CONTAINERS=()
NETWORKS=()
VOLUME=

cleanup() {
  local container network
  for container in "${CONTAINERS[@]}"; do docker rm -f "$container" > /dev/null; done
  for network in "${NETWORKS[@]}"; do docker network rm "$network" > /dev/null; done
  if [[ -n $VOLUME ]]; then docker volume rm "$VOLUME" > /dev/null; fi
  rm -r -- "$WORK"
}
trap cleanup EXIT
diagnose_failure() {
  local line=$1 command=$2 log
  printf 'Shared-profile test failed at line %s: %s\n' "$line" "$command" >&2
  for log in rejected pools sas; do
    if [[ -f $WORK/$log ]]; then cat "$WORK/$log" >&2; fi
  done
}
trap 'diagnose_failure "$LINENO" "$BASH_COMMAND"' ERR

wait_ready() {
  local container=$1 marker=$2 attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if docker exec "$container" test -f "$marker"; then return; fi
    sleep 1
  done
  docker logs "$container" >&2
  docker exec "$container" cat /run/shared-charon.log >&2
  echo "Timed out waiting for $container." >&2
  exit 1
}

server_count() {
  docker exec "$PREFIX-server" swanctl --list-sas > "$WORK/sas"
  awk '/internet: #.*INSTALLED/ {count++} END {print count+0}' "$WORK/sas"
}

for network in upstream clients; do
  docker network create "$PREFIX-$network" > /dev/null
  NETWORKS+=("$PREFIX-$network")
done
VOLUME=$(docker volume create "$PREFIX-state")
CONTAINERS+=("$PREFIX-server")
docker run -d --name "$PREFIX-server" --network "$PREFIX-upstream" --cap-add NET_ADMIN \
  --mount "type=volume,source=$VOLUME,target=/shared" \
  -e SHARED_PROFILE_SERVER=1 vpn-validation > /dev/null
wait_ready "$PREFIX-server" /shared/ready
SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PREFIX-server")

CONTAINERS+=("$PREFIX-router")
docker run -d --name "$PREFIX-router" --network "$PREFIX-upstream" --cap-add NET_ADMIN \
  --sysctl net.ipv4.ip_forward=1 vpn-validation sleep infinity > /dev/null
docker network connect "$PREFIX-clients" "$PREFIX-router"
ROUTER_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$PREFIX-clients\").IPAddress}}" "$PREFIX-router")
docker exec "$PREFIX-router" bash -c \
  'nft add table ip nat; nft "add chain ip nat postrouting { type nat hook postrouting priority srcnat; policy accept; }"; nft add rule ip nat postrouting masquerade'

for device in {1..21}; do
  name="$PREFIX-client-$device"
  CONTAINERS+=("$name")
  docker run -d --name "$name" --network "$PREFIX-clients" --cap-add NET_ADMIN \
    --mount "type=volume,source=$VOLUME,target=/shared,readonly" \
    -e "SERVER_IP=$SERVER_IP" -e "ROUTER_IP=$ROUTER_IP" \
    vpn-validation bash tests/shared-client.sh > /dev/null
  wait_ready "$name" /run/shared-ready
  if [[ $device -le 20 ]]; then
    if ! docker exec "$name" swanctl --initiate --child internet --timeout 20 > "$WORK/initiate" 2>&1; then
      cat "$WORK/initiate" >&2
      docker logs "$PREFIX-server" >&2
      exit 1
    fi
    [[ $(server_count) == "$device" ]] || { cat "$WORK/sas" >&2; exit 1; }
  fi
done

printf '20 shared-identity tunnels are established behind one NAT.\n'
if docker exec "$PREFIX-client-21" swanctl --initiate --child internet --timeout 20 > "$WORK/rejected" 2>&1; then
  echo 'The 21st shared-profile connection must be rejected.' >&2
  exit 1
fi
grep -q 'INTERNAL_ADDRESS_FAILURE' "$WORK/rejected"
[[ $(server_count) == 20 ]]
docker exec "$PREFIX-server" swanctl --list-pools --leases > "$WORK/pools"
awk '$1 == "vpn4" && $3 == 20 && $5 == 0 && $7 == 20 {found=1} END {exit !found}' "$WORK/pools"
awk '$1 == "vpn6" && $3 == 20 && $5 == 0 && $7 == 20 {found=1} END {exit !found}' "$WORK/pools"

for device in {1..20}; do
  name="$PREFIX-client-$device"
  vip=$(docker exec "$name" ip -o -4 address show |
    awk '$4 ~ /^10[.]78[.]/ {split($4,a,"/"); print a[1]}')
  [[ $vip =~ ^10\.78\.0\.([1-9]|1[0-9]|20)$ ]]
  printf '%s\n' "$vip" >> "$WORK/addresses"
  docker exec "$name" ping -n -c 1 -W 3 -I "$vip" 198.18.0.1 > /dev/null
done
[[ $(sort -u "$WORK/addresses" | wc -l) == 20 ]]

docker exec "$PREFIX-client-1" swanctl --terminate --ike shared --timeout 10 > /dev/null
[[ $(server_count) == 19 ]]
docker exec "$PREFIX-client-21" swanctl --terminate --ike shared --timeout 10 > /dev/null
docker exec "$PREFIX-client-21" swanctl --initiate --child internet --timeout 20 > "$WORK/reused" 2>&1
[[ $(server_count) == 20 ]]
printf '20 simultaneous shared-certificate clients behind one NAT passed; unique IPv4/IPv6 leases, traffic, 21st-client rejection, and released-slot reuse verified.\n'
