#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/bootstrap.sh
source "$ROOT/scripts/bootstrap.sh"
WORK=$(mktemp -d "$ROOT/.bootstrap-test.XXXXXX")
trap cleanup EXIT
export VPN_HOST=vpn-test.denmarkeast.cloudapp.azure.com
STATE_DIR="$WORK/state"
export MSYS2_ARG_CONV_EXCL='/CN='

if [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]; then
  jq() {
    local arg
    local -a args=()
    for arg in "$@"; do
      if [[ $arg == "$WORK/"* ]]; then arg=$(cygpath -m "$arg"); fi
      args+=("$arg")
    done
    # Native jq must receive slash-prefixed base64 keys without MSYS path rewriting.
    MSYS2_ARG_CONV_EXCL='*' command jq -b "${args[@]}"
  }
  openssl() {
    local arg
    local -a args=()
    for arg in "$@"; do
      if [[ $arg == file:/* ]]; then arg="file:$(cygpath -m "${arg#file:}")"; fi
      args+=("$arg")
    done
    command openssl "${args[@]}"
  }
fi

# Test rendering independently of a loaded WireGuard kernel module.
wg() {
  case "$1" in
    genkey|genpsk) openssl rand -base64 32 ;;
    pubkey) openssl dgst -sha256 -binary | openssl base64 -A ;;
    *) return 1 ;;
  esac
}

mock_existing_state_generation() {
  generate_state() { fail 'Existing state must never generate replacement credentials.'; }
}

mock_secret_publication() {
  put_secret() {
    [[ $(wc -c < "$2") -le 25000 ]] || fail 'Published secret exceeds the Key Vault size limit.'
    cp "$2" "$WORK/published/$1"
  }
}

generate_state "$STATE_DIR"
render_wireguard
render_ikev2
render_profile
render_firewall eth0
openssl verify -CAfile "$STATE_DIR/ca.crt" -purpose sslserver -verify_hostname "$VPN_HOST" "$STATE_DIR/server.crt"
openssl verify -CAfile "$STATE_DIR/ca.crt" -purpose sslclient -verify_hostname vpn-client "$STATE_DIR/client.crt"
openssl x509 -in "$STATE_DIR/client.crt" -noout -subject | grep -Eq 'CN ?= ?vpn-client$'
openssl pkcs12 -legacy -in "$STATE_DIR/client.p12" -passin "file:$STATE_DIR/p12-password" -noout

"${PYTHON:-python3}" - "$WORK/ikev2-vpn.mobileconfig" "$VPN_HOST" <<'PY'
import plistlib
import sys
import uuid

with open(sys.argv[1], "rb") as stream:
    profile = plistlib.load(stream)
root, identity, vpn = profile["PayloadContent"]
assert root["PayloadType"] == "com.apple.security.root"
assert identity["PayloadType"] == "com.apple.security.pkcs12"
assert profile["PayloadDisplayName"] == vpn["UserDefinedName"] == f"IKEv2 VPN {sys.argv[2]}"
assert len(root["PayloadContent"]) > 500 and len(identity["PayloadContent"]) > 2000
ike = vpn["IKEv2"]
assert ike["PayloadCertificateUUID"] == identity["PayloadUUID"]
assert ike["RemoteIdentifier"] == ike["RemoteAddress"] == sys.argv[2]
assert ike["LocalIdentifier"] == "vpn-client"
assert ike["AuthenticationMethod"] == "Certificate" and ike["ExtendedAuthEnabled"] == 0
assert ike["IncludeAllNetworks"] == 1 and ike["EnablePFS"] == 1
for key in ("IKESecurityAssociationParameters", "ChildSecurityAssociationParameters"):
    assert ike[key]["EncryptionAlgorithm"] == "AES-256"
    assert ike[key]["IntegrityAlgorithm"] == "SHA2-256"
    assert ike[key]["DiffieHellmanGroup"] == 14
for payload in [profile, *profile["PayloadContent"]]:
    assert uuid.UUID(payload["PayloadUUID"]).version == 4
print("Apple profile structure, identity links, and cryptographic proposals passed.")
PY

validate_address_plan() {
  local profile
  printf '%s\n' "$(wg pubkey < "$STATE_DIR/wg-server.key")" > "$WORK/public-keys"
  for profile in "$WORK"/wireguard-*.conf; do
    printf '%s\n' "$(awk '/^PrivateKey = / {print $3}' "$profile" | wg pubkey)"
  done >> "$WORK/public-keys"
  "${PYTHON:-python3}" - "$WORK" "$ROOT/templates/regional.bicep" "$STATE_DIR/wireguard-clients.json" <<'PY'
import configparser
import ipaddress
import json
from pathlib import Path
import re
import sys


def wireguard(text):
    interface, *sections = text.split("[Peer]")
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(interface)
    peers = []
    for section in sections:
        peer = configparser.ConfigParser(interpolation=None)
        peer.read_string("[Peer]" + section)
        peers.append(dict(peer["Peer"]))
    return dict(config["Interface"]), peers


def csv(value, parse):
    return [parse(item.strip()) for item in value.split(",")]


def validate(server_text, clients, ike_text, subnet):
    interface, peers = wireguard(server_text)
    server_addresses = csv(interface["address"], ipaddress.ip_interface)
    assert sorted(address.version for address in server_addresses) == [4, 6]
    networks = {address.version: address.network for address in server_addresses}
    server_ips = {address.ip for address in server_addresses}
    assert len(clients) == len(peers) == 20
    peers_by_key = {peer["publickey"]: peer for peer in peers}
    assert len(peers_by_key) == 20, "WireGuard peer public keys reused"
    assert len({peer["presharedkey"] for peer in peers}) == 20
    used_addresses = set()
    peer_prefixes = []
    for client_text, public_key in clients:
        client, remotes = wireguard(client_text)
        assert len(remotes) == 1
        remote = remotes[0]
        addresses = csv(client["address"], ipaddress.ip_interface)
        assert sorted(address.version for address in addresses) == [4, 6]
        for address in addresses:
            assert address.network.prefixlen == address.max_prefixlen
            assert address.ip in networks[address.version], "WireGuard client outside server network"
            assert address.ip not in server_ips, "WireGuard client uses server address"
            assert address.ip not in used_addresses, "WireGuard client address reused"
            used_addresses.add(address.ip)
        peer = peers_by_key[public_key]
        prefixes = csv(peer["allowedips"], ipaddress.ip_network)
        assert set(prefixes) == {address.network for address in addresses}, "Server peer prefixes differ from client"
        assert peer["presharedkey"] == remote["presharedkey"]
        assert remote["publickey"] == server_public
        peer_prefixes.extend(prefixes)
        # Default routes intentionally repeat on separate client devices, never server peers.
        assert set(csv(remote["allowedips"], ipaddress.ip_network)) == {
            ipaddress.ip_network("0.0.0.0/0"), ipaddress.ip_network("::/0")
        }
    assert len(used_addresses) == 40
    for index, prefix in enumerate(peer_prefixes):
        assert all(not prefix.overlaps(other) for other in peer_prefixes[index + 1:]
                   if prefix.version == other.version), "Server peer prefixes overlap"

    pools_block = re.search(r"(?ms)^pools\s*\{(.*)\}\s*$", ike_text)
    assert pools_block, "Missing rendered IKEv2 pools"
    pools = re.findall(r"(\w+)\s*\{\s*addrs\s*=\s*(\S+)", pools_block[1])
    assert len(pools) == 2 and len({name for name, _ in pools}) == 2
    selected = re.findall(r"(?m)^\s*pools\s*=\s*(.+)$", ike_text)
    assert len(selected) == 1 and set(csv(selected[0], str)) == {name for name, _ in pools}
    pool_versions = []
    for _, value in pools:
        first, last = map(ipaddress.ip_address, value.split("-"))
        assert first.version == last.version
        assert int(last) - int(first) + 1 == 20, "IKEv2 pool must contain exactly 20 addresses"
        pool_versions.append(first.version)
        for prefix in ipaddress.summarize_address_range(first, last):
            assert not prefix.overlaps(networks[first.version]), "WireGuard and IKEv2 pools overlap"
            if first.version == 4:
                assert not prefix.overlaps(subnet), "Azure subnet overlaps IKEv2 pool"
    assert sorted(pool_versions) == [4, 6]
    assert not subnet.overlaps(networks[4]), "Azure subnet overlaps WireGuard network"


work = Path(sys.argv[1])
server_text = (work / "wg0.conf").read_text()
profiles = sorted(work.glob("wireguard-*.conf"))
assert [path.name for path in profiles] == [f"wireguard-{device:02d}.conf" for device in range(1, 21)]
public_keys = (work / "public-keys").read_text().splitlines()
assert len(public_keys) == 21
server_public, *client_public_keys = public_keys
clients = [(path.read_text(), key) for path, key in zip(profiles, client_public_keys)]
saved_clients = json.loads(Path(sys.argv[3]).read_text())
assert len(saved_clients) == 20
for (text, _), saved in zip(clients, saved_clients):
    interface, peers = wireguard(text)
    assert interface["privatekey"] == saved["privateKey"]
    assert peers[0]["presharedkey"] == saved["presharedKey"]
ike_text = (work / "swanctl.conf").read_text()
template = Path(sys.argv[2]).read_text()
subnet_block = re.search(r"(?ms)^resource subnet\b.*?^}", template)
assert subnet_block, "Missing Azure subnet resource"
subnet_prefixes = re.findall(r"\baddressPrefix:\s*'([^']+)'", subnet_block[0])
assert len(subnet_prefixes) == 1, "Expected one literal Azure subnet prefix"
subnet = ipaddress.ip_network(subnet_prefixes[0])
assert subnet.version == 4
validate(server_text, clients, ike_text, subnet)

# Feed corrupt rendered configurations through the same complete validator.
interface, _ = wireguard(server_text)
for address in csv(interface["address"], ipaddress.ip_interface):
    first = address.network.network_address + 1
    last = first + 19
    colliding = re.sub(
        r"(addrs\s*=\s*)(\S+)",
        lambda match: match[1] + f"{first}-{last}"
        if ipaddress.ip_address(match[2].split("-")[0]).version == address.version else match[0],
        ike_text,
    )
    assert colliding != ike_text
    try:
        validate(server_text, clients, colliding, subnet)
    except AssertionError as error:
        assert str(error) == "WireGuard and IKEv2 pools overlap"
    else:
        raise AssertionError("Colliding rendered IKEv2 pool was accepted")

duplicate_clients = clients.copy()
first_client, _ = wireguard(clients[0][0])
duplicate_clients[1] = (
    re.sub(r"(?m)^Address = .+$", f"Address = {first_client['address']}", clients[1][0]),
    clients[1][1],
)
try:
    validate(server_text, duplicate_clients, ike_text, subnet)
except AssertionError as error:
    assert str(error) == "WireGuard client address reused"
else:
    raise AssertionError("Duplicate rendered WireGuard client address was accepted")
print("Rendered dual-stack address isolation, 20 peer/key bindings, full-tunnel routes, Azure subnet, and collision controls passed.")
PY
}

validate_address_plan

grep -q 'AllowedIPs = 0.0.0.0/0, ::/0' "$WORK/wireguard-01.conf"
grep -q 'remote_ts = dynamic' "$WORK/swanctl.conf"
grep -q 'id = vpn-client' "$WORK/swanctl.conf"
grep -q 'id = vpn-client' "$ROOT/tests/shared-client.sh"
grep -q 'meta nfproto ipv6 drop' "$WORK/nftables.conf"
grep -q '169.254.0.0/16' "$WORK/nftables.conf"

backup_state() {
  local dir=$1
  local -a files=("$dir"/*)
  tar -czf "$WORK/backup.tgz" -C "$dir" "${files[@]##*/}"
  base64 -w0 "$WORK/backup.tgz" > "$WORK/backup.b64"
}
backup_state "$STATE_DIR"
[[ $(wc -c < "$WORK/ikev2-vpn.mobileconfig") -le 25000 ]]

VAULT_RESULT=0
vault_request() {
  if [[ $VAULT_RESULT == 0 ]]; then
    jq -n --rawfile value "$WORK/backup.b64" '{value:$value}' > "$WORK/response"
  fi
  return "$VAULT_RESULT"
}
printf '%25000s' '' > "$WORK/size-limit"
put_secret size-limit-test "$WORK/size-limit"
printf 'x' >> "$WORK/size-limit"
if (put_secret size-limit-test "$WORK/size-limit") > "$WORK/error.log" 2>&1; then
  fail 'Secrets above the exact 25000-byte limit must be rejected.'
fi
grep -q 'exceeds the Key Vault secret size limit' "$WORK/error.log"
cp -R "$STATE_DIR" "$WORK/original"
mkdir "$WORK/original-profiles"
cp "$WORK"/wireguard-*.conf "$WORK/original-profiles/"
mock_existing_state_generation
restore_state
render_wireguard
for device in {1..20}; do
  printf -v number '%02d' "$device"
  cmp "$WORK/original-profiles/wireguard-${number}.conf" "$WORK/wireguard-${number}.conf"
done
validate_address_plan
restore_state
diff -qr "$STATE_DIR" "$WORK/original"
mkdir "$WORK/published"
mock_secret_publication
publish_state
[[ $(find "$WORK/published" -type f | wc -l) == 22 ]]
[[ ! -e $WORK/published/wireguard-client-config && ! -e $WORK/published/iphone-profile ]]
for device in {1..20}; do
  printf -v number '%02d' "$device"
  cmp "$WORK/wireguard-${number}.conf" "$WORK/published/wireguard-client-${number}-config"
done
cmp "$WORK/ikev2-vpn.mobileconfig" "$WORK/published/ikev2-client-profile"
cp "$WORK/published/vpn-state" "$WORK/backup.b64"
[[ $(wc -c < "$WORK/backup.b64") -le 25000 ]]
base64 -d "$WORK/backup.b64" > "$WORK/published.tgz"
tar -tzf "$WORK/published.tgz" | sort > "$WORK/published-files"
printf '%s\n' ca.key ca.crt server.key server.crt client.key client.crt client.p12 \
  p12-password wg-server.key endpoint wireguard-clients.json | sort > "$WORK/expected-files"
cmp "$WORK/published-files" "$WORK/expected-files"
rm -r "$STATE_DIR"
restore_state
diff -qr "$STATE_DIR" "$WORK/original"
restore_state
diff -qr "$STATE_DIR" "$WORK/original"

VAULT_RESULT=4
restore_state
diff -qr "$STATE_DIR" "$WORK/original"

expect_restore_failure() {
  local message=$1
  if (restore_state) > "$WORK/error.log" 2>&1; then
    fail 'Invalid or conflicting state was accepted.'
  fi
  grep -q "$message" "$WORK/error.log"
  rm -rf "$WORK/restored"
}

# Missing state is an error, never a request to create missing credentials.
for file in wireguard-clients.json wg-server.key client.p12; do
  mv "$STATE_DIR/$file" "$WORK/missing-file"
  expect_restore_failure "Missing or invalid state file: $file"
  VAULT_RESULT=0
  expect_restore_failure "Missing or invalid state file: $file"
  [[ ! -e $STATE_DIR/$file ]]
  mv "$WORK/missing-file" "$STATE_DIR/$file"
  VAULT_RESULT=4
done

for filter in \
  '.[0].privateKey = "invalid"' \
  '.[0].presharedKey = "invalid"' \
  '.[0].privateKey = .[1].privateKey' \
  '.[0].presharedKey = .[1].presharedKey' \
  'del(.[0].privateKey)' \
  '.[0:19]' \
  '. + [.[0]]'; do
  jq "$filter" "$WORK/original/wireguard-clients.json" > "$STATE_DIR/wireguard-clients.json"
  cp "$STATE_DIR/wireguard-clients.json" "$WORK/invalid-clients.json"
  expect_restore_failure 'Invalid WireGuard client keys'
  cmp "$STATE_DIR/wireguard-clients.json" "$WORK/invalid-clients.json"
done
cp "$WORK/original/wireguard-clients.json" "$STATE_DIR/wireguard-clients.json"
printf 'unexpected\n' > "$STATE_DIR/unexpected"
expect_restore_failure 'Unexpected file in VPN state'
rm "$STATE_DIR/unexpected"

# Well-formed but conflicting keys must also fail the complete state comparison.
VAULT_RESULT=0
jq 'reverse' "$WORK/original/wireguard-clients.json" > "$STATE_DIR/wireguard-clients.json"
expect_restore_failure 'Local and Key Vault state differ; refusing to overwrite credentials'
cp "$WORK/original/wireguard-clients.json" "$STATE_DIR/wireguard-clients.json"

cp -R "$WORK/original" "$WORK/incomplete"
rm "$WORK/incomplete/wireguard-clients.json"
backup_state "$WORK/incomplete"
expect_restore_failure 'Missing or invalid state file: wireguard-clients.json'
diff -qr "$STATE_DIR" "$WORK/original"
rm -r "$STATE_DIR"
expect_restore_failure 'Missing or invalid state file: wireguard-clients.json'
[[ ! -e $STATE_DIR ]]
cp -R "$WORK/original" "$STATE_DIR"
backup_state "$WORK/original"
cp "$WORK/backup.b64" "$WORK/valid-backup.b64"
printf 'not-base64!\n' > "$WORK/backup.b64"
expect_restore_failure 'Invalid VPN state backup encoding'
printf 'not an archive' | base64 -w0 > "$WORK/backup.b64"
expect_restore_failure 'Invalid VPN state archive'
cp "$WORK/valid-backup.b64" "$WORK/backup.b64"

VAULT_RESULT=1
expect_restore_failure 'refusing to generate replacement keys'
VAULT_RESULT=0
printf 'different\n' > "$STATE_DIR/endpoint"
expect_restore_failure 'Saved VPN endpoint differs'
cp "$WORK/original/endpoint" "$STATE_DIR/endpoint"
diff -qr "$STATE_DIR" "$WORK/original"
printf 'Certificates, 20 distinct WireGuard profiles, publication shape, secret sizes, restore, idempotency, and fail-closed recovery passed.\n'
