#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR=/etc/vpn-state
WORK=
TOKEN=

fail() { printf 'VPN bootstrap: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n $WORK ]]; then rm -rf -- "$WORK"; fi
}

# Refresh for each request: RBAC propagation can outlast an IMDS token's lifetime.
vault_request() {
  local method=$1 secret=$2 body=${3:-} status attempt
  for attempt in {1..60}; do
    TOKEN=$(curl --fail --silent --show-error --noproxy '*' --connect-timeout 10 --max-time 30 \
      -H Metadata:true \
      'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' |
      jq -er .access_token) || fail 'Managed identity token request failed.'
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$TOKEN" > "$WORK/headers"
    local -a options=(--silent --show-error --connect-timeout 10 --max-time 60
      --request "$method" --header "@$WORK/headers" --output "$WORK/response" --write-out '%{http_code}')
    if [[ -n $body ]]; then options+=(--data-binary "@$body"); fi
    status=$(curl "${options[@]}" "https://${VPN_VAULT}.vault.azure.net/secrets/${secret}?api-version=7.4") ||
      fail "Key Vault transport request failed for $method $secret."
    case "$status" in
      200) return 0 ;;
      404)
        if [[ $method == GET ]]; then return 4; fi
        fail "Key Vault returned HTTP 404 while writing $secret."
        ;;
      403|429|500|502|503|504)
        printf 'Waiting for Key Vault readiness (%s/60, HTTP %s).\n' "$attempt" "$status" >&2
        sleep 10
        ;;
      *) fail "Key Vault returned HTTP $status for $method $secret." ;;
    esac
  done
  fail "Key Vault access did not become ready for $method $secret."
}

put_secret() {
  local name=$1 file=$2
  [[ $(wc -c < "$file") -le 25000 ]] || fail "$name exceeds the Key Vault secret size limit."
  jq -n --rawfile value "$file" '{value:$value}' > "$WORK/request"
  vault_request PUT "$name" "$WORK/request"
}

generate_state() {
  local dir=$1
  mkdir -m 700 "$dir"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$dir/ca.key" 2>/dev/null
  openssl req -new -x509 -sha256 -days 3650 -key "$dir/ca.key" -out "$dir/ca.crt" \
    -subj '/CN=Regional VPN CA' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign'
  local name identity
  for name in server client; do
    identity=$name
    if [[ $name == client ]]; then identity=vpn-client; fi
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$dir/$name.key" 2>/dev/null
    openssl req -new -key "$dir/$name.key" -out "$WORK/$name.csr" -subj "/CN=$identity"
    if [[ $name == server ]]; then
      printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$VPN_HOST" > "$WORK/extensions"
    else
      printf 'subjectAltName=DNS:vpn-client\nextendedKeyUsage=clientAuth\n' > "$WORK/extensions"
    fi
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n' >> "$WORK/extensions"
    openssl x509 -req -sha256 -days 825 -in "$WORK/$name.csr" -CA "$dir/ca.crt" \
      -CAkey "$dir/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
      -extfile "$WORK/extensions" -out "$dir/$name.crt" 2>/dev/null
  done
  openssl rand -base64 24 > "$dir/p12-password"
  # Apple's importer requires the legacy PKCS#12 encoding, not legacy VPN ciphers.
  openssl pkcs12 -export -legacy -inkey "$dir/client.key" -in "$dir/client.crt" \
    -name 'IKEv2 VPN client' -passout "file:$dir/p12-password" -out "$dir/client.p12"
  wg genkey > "$dir/wg-server.key"
  printf '%s\n' "$VPN_HOST" > "$dir/endpoint"
  local device
  : > "$WORK/wireguard-clients.ndjson"
  for ((device=1; device<=20; device++)); do
    jq -n --arg privateKey "$(wg genkey)" --arg presharedKey "$(wg genpsk)" \
      '{privateKey:$privateKey,presharedKey:$presharedKey}' >> "$WORK/wireguard-clients.ndjson"
  done
  jq -s . "$WORK/wireguard-clients.ndjson" > "$dir/wireguard-clients.json"
}

validate_state() {
  local dir=$1 file
  for file in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e $file || -L $file ]] || continue
    case "${file##*/}" in
      ca.key|ca.crt|server.key|server.crt|client.key|client.crt|client.p12|p12-password|wg-server.key|endpoint|wireguard-clients.json) ;;
      *) fail 'Unexpected file in VPN state.' ;;
    esac
  done
  for file in ca.key ca.crt server.key server.crt client.key client.crt client.p12 p12-password wg-server.key endpoint wireguard-clients.json; do
    [[ -f $dir/$file && -s $dir/$file && ! -L $dir/$file ]] || fail "Missing or invalid state file: $file"
  done
  [[ $(cat "$dir/endpoint") == "$VPN_HOST" ]] || fail 'Saved VPN endpoint differs from this deployment.'
  jq -e 'type == "array" and length == 20 and all(.[];
    type == "object" and keys == ["presharedKey", "privateKey"] and
    (.privateKey | type == "string" and test("^[A-Za-z0-9+/]{43}=$")) and
    (.presharedKey | type == "string" and test("^[A-Za-z0-9+/]{43}=$"))) and
    ([.[].privateKey] | unique | length == 20) and
    ([.[].presharedKey] | unique | length == 20)' \
    "$dir/wireguard-clients.json" > /dev/null || fail 'Invalid WireGuard client keys.'
}

restore_state() {
  local result=0 entry
  vault_request GET vpn-state || result=$?
  if [[ $result == 0 ]]; then
    jq -er .value "$WORK/response" | base64 -d > "$WORK/state.tgz" ||
      fail 'Invalid VPN state backup encoding.'
    tar -tzf "$WORK/state.tgz" > "$WORK/state-files" || fail 'Invalid VPN state archive.'
    while IFS= read -r entry; do
      case "$entry" in
        ca.key|ca.crt|server.key|server.crt|client.key|client.crt|client.p12|p12-password|wg-server.key|endpoint|wireguard-clients.json) ;;
        *) fail 'Unexpected file in VPN state backup.' ;;
      esac
    done < "$WORK/state-files"
    mkdir -m 700 "$WORK/restored"
    tar -xzf "$WORK/state.tgz" -C "$WORK/restored" --no-same-owner --no-same-permissions ||
      fail 'Could not extract VPN state archive.'
    validate_state "$WORK/restored"
    if [[ -d $STATE_DIR ]]; then
      validate_state "$STATE_DIR"
      diff -qr "$STATE_DIR" "$WORK/restored" > /dev/null ||
        fail 'Local and Key Vault state differ; refusing to overwrite credentials.'
      rm -r -- "$WORK/restored"
    else
      mv "$WORK/restored" "$STATE_DIR"
    fi
  elif [[ $result == 4 ]]; then
    if [[ ! -d $STATE_DIR ]]; then
      generate_state "$WORK/generated"
      mv "$WORK/generated" "$STATE_DIR"
    fi
  else
    fail 'Could not retrieve existing VPN state; refusing to generate replacement keys.'
  fi
  validate_state "$STATE_DIR"
  local file
  chmod 700 "$STATE_DIR"
  chmod 600 "$STATE_DIR"/*
  for file in ca server client; do
    openssl x509 -in "$STATE_DIR/$file.crt" -checkend 2592000 -noout > /dev/null ||
      fail "$file certificate expires within 30 days. Rotate credentials; see README."
  done
  openssl verify -CAfile "$STATE_DIR/ca.crt" -purpose sslserver -verify_hostname "$VPN_HOST" \
    "$STATE_DIR/server.crt" > /dev/null
  openssl verify -CAfile "$STATE_DIR/ca.crt" -purpose sslclient -verify_hostname vpn-client \
    "$STATE_DIR/client.crt" > /dev/null
}

render_wireguard() {
  local device private psk address ipv6 number server_public
  server_public=$(wg pubkey < "$STATE_DIR/wg-server.key")
  cat > "$WORK/wg0.conf" <<EOF
[Interface]
Address = 10.77.0.1/24, fd77::1/64
ListenPort = 51820
PrivateKey = $(cat "$STATE_DIR/wg-server.key")
EOF
  for ((device=1; device<=20; device++)); do
    printf -v number '%02d' "$device"
    address=$((device + 1))
    printf -v ipv6 '%x' "$address"
    private=$(jq -er --argjson index "$((device - 1))" '.[$index].privateKey' "$STATE_DIR/wireguard-clients.json")
    psk=$(jq -er --argjson index "$((device - 1))" '.[$index].presharedKey' "$STATE_DIR/wireguard-clients.json")
    cat >> "$WORK/wg0.conf" <<EOF
[Peer]
PublicKey = $(printf '%s\n' "$private" | wg pubkey)
PresharedKey = $psk
AllowedIPs = 10.77.0.${address}/32, fd77::${ipv6}/128

EOF
    cat > "$WORK/wireguard-${number}.conf" <<EOF
[Interface]
PrivateKey = $private
Address = 10.77.0.${address}/32, fd77::${ipv6}/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = $server_public
PresharedKey = $psk
Endpoint = ${VPN_HOST}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  done
}

render_ikev2() {
  cat > "$WORK/swanctl.conf" <<EOF
connections {
  ikev2 {
    version = 2
    unique = never
    proposals = aes256-sha256-modp2048
    pools = vpn4, vpn6
    fragmentation = yes
    mobike = yes
    encap = yes
    dpd_delay = 30s
    send_cert = always
    local {
      auth = pubkey
      certs = server.crt
      id = ${VPN_HOST}
    }
    remote {
      auth = pubkey
      id = vpn-client
      cacerts = ca.crt
    }
    children {
      internet {
        local_ts = 0.0.0.0/0, ::/0
        remote_ts = dynamic
        esp_proposals = aes256-sha256-modp2048
        reqid = 1
        dpd_action = clear
      }
    }
  }
}
pools {
  vpn4 {
    addrs = 10.78.0.1-10.78.0.20
    dns = 1.1.1.1, 1.0.0.1
  }
  vpn6 {
    addrs = fd78::1-fd78::14
  }
}
EOF
}

render_profile() {
  local profile_uuid vpn_uuid ca_uuid cert_uuid
  profile_uuid=$(new_uuid)
  vpn_uuid=$(new_uuid)
  ca_uuid=$(new_uuid)
  cert_uuid=$(new_uuid)
  cat > "$WORK/ikev2-vpn.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadType</key><string>Configuration</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>net.regionalvpn.${VPN_HOST}</string>
<key>PayloadUUID</key><string>${profile_uuid}</string>
<key>PayloadDisplayName</key><string>IKEv2 VPN ${VPN_HOST}</string>
<key>PayloadContent</key><array>
<dict>
<key>PayloadType</key><string>com.apple.security.root</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>net.regionalvpn.${VPN_HOST}.ca</string>
<key>PayloadUUID</key><string>${ca_uuid}</string>
<key>PayloadContent</key><data>$(openssl x509 -in "$STATE_DIR/ca.crt" -outform DER | base64 -w0)</data>
</dict>
<dict>
<key>PayloadType</key><string>com.apple.security.pkcs12</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>net.regionalvpn.${VPN_HOST}.client</string>
<key>PayloadUUID</key><string>${cert_uuid}</string>
<key>Password</key><string>$(cat "$STATE_DIR/p12-password")</string>
<key>PayloadContent</key><data>$(base64 -w0 "$STATE_DIR/client.p12")</data>
</dict>
<dict>
<key>PayloadType</key><string>com.apple.vpn.managed</string>
<key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>net.regionalvpn.${VPN_HOST}.vpn</string>
<key>PayloadUUID</key><string>${vpn_uuid}</string>
<key>UserDefinedName</key><string>IKEv2 VPN ${VPN_HOST}</string>
<key>VPNType</key><string>IKEv2</string>
<key>IPv4</key><dict><key>OverridePrimary</key><integer>1</integer></dict>
<key>IKEv2</key><dict>
<key>RemoteAddress</key><string>${VPN_HOST}</string>
<key>RemoteIdentifier</key><string>${VPN_HOST}</string>
<key>LocalIdentifier</key><string>vpn-client</string>
<key>AuthenticationMethod</key><string>Certificate</string>
<key>CertificateType</key><string>RSA</string>
<key>ExtendedAuthEnabled</key><integer>0</integer>
<key>PayloadCertificateUUID</key><string>${cert_uuid}</string>
<key>ServerCertificateIssuerCommonName</key><string>Regional VPN CA</string>
<key>ServerCertificateCommonName</key><string>${VPN_HOST}</string>
<key>DisableMOBIKE</key><integer>0</integer>
<key>EnablePFS</key><integer>1</integer>
<key>IncludeAllNetworks</key><integer>1</integer>
<key>IKESecurityAssociationParameters</key><dict>
<key>EncryptionAlgorithm</key><string>AES-256</string>
<key>IntegrityAlgorithm</key><string>SHA2-256</string>
<key>DiffieHellmanGroup</key><integer>14</integer>
<key>LifeTimeInMinutes</key><integer>240</integer>
</dict>
<key>ChildSecurityAssociationParameters</key><dict>
<key>EncryptionAlgorithm</key><string>AES-256</string>
<key>IntegrityAlgorithm</key><string>SHA2-256</string>
<key>DiffieHellmanGroup</key><integer>14</integer>
<key>LifeTimeInMinutes</key><integer>60</integer>
</dict>
</dict></dict>
</array></dict></plist>
EOF
}

new_uuid() {
  openssl rand -hex 16 | sed -E 's/(.{8})(.{4}).(.{3}).(.{3})(.{12})/\1-\2-4\3-a\4-\5/'
}

render_firewall() {
  local uplink=$1
  cat > "$WORK/nftables.conf" <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet vpn {
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept
    udp dport { 500, 4500, 51820 } accept
    iifname "wg0" ip saddr 10.77.0.0/24 tcp dport 22 accept
    ip saddr 10.78.0.0/24 ipsec in reqid 1 tcp dport 22 accept
    ip protocol icmp accept
    meta l4proto ipv6-icmp accept
    udp sport 67 udp dport 68 accept
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    # IPv6 is captured by clients but deliberately not routed to the Internet.
    meta nfproto ipv6 drop
    ct state invalid drop
    ct state established,related accept
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 168.63.129.16/32 } drop
    iifname "wg0" ip saddr 10.77.0.0/24 oifname "${uplink}" accept
    ip saddr 10.78.0.0/24 ipsec in reqid 1 oifname "${uplink}" accept
  }
  chain output {
    type filter hook output priority filter; policy accept;
  }
}
table ip vpn_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr { 10.77.0.0/24, 10.78.0.0/24 } oifname "${uplink}" masquerade
  }
}
table ip vpn_mss {
  chain forward {
    type filter hook forward priority mangle; policy accept;
    tcp flags & (syn | rst) == syn tcp option maxseg size > 1200 tcp option maxseg size set 1200
  }
}
EOF
}

publish_state() {
  tar -czf "$WORK/state.tgz" -C "$STATE_DIR" ca.key ca.crt server.key server.crt client.key client.crt \
    client.p12 p12-password wg-server.key endpoint wireguard-clients.json
  base64 -w0 "$WORK/state.tgz" > "$WORK/state.b64"
  put_secret vpn-state "$WORK/state.b64"
  local device number
  for ((device=1; device<=20; device++)); do
    printf -v number '%02d' "$device"
    put_secret "wireguard-client-${number}-config" "$WORK/wireguard-${number}.conf"
  done
  put_secret ikev2-client-profile "$WORK/ikev2-vpn.mobileconfig"
}

main() {
  [[ $EUID == 0 ]] || fail 'Run as root.'
  [[ ${VPN_VAULT:-} =~ ^[a-zA-Z0-9-]{3,24}$ ]] || fail 'Invalid VPN_VAULT.'
  [[ ${VPN_HOST:-} =~ ^[a-z0-9.-]+\.cloudapp\.azure\.com$ ]] || fail 'Invalid VPN_HOST.'
  exec 9>/run/vpn-bootstrap.lock
  flock -n 9 || fail 'Another bootstrap is running.'
  WORK=$(mktemp -d /var/tmp/vpn-bootstrap.XXXXXX)
  trap cleanup EXIT
  trap 'printf "VPN bootstrap failed at line %s.\n" "$LINENO" >&2' ERR
  export DEBIAN_FRONTEND=noninteractive
  cloud-init status --wait > /dev/null
  apt-get update -qq
  apt-get install -y --no-install-recommends wireguard-tools strongswan-swanctl charon-systemd \
    libstrongswan-standard-plugins libcharon-extra-plugins openssl curl jq nftables netbase unattended-upgrades
  modprobe wireguard
  restore_state
  render_wireguard
  render_ikev2
  render_profile
  local uplink
  uplink=$(ip -4 route show default | awk 'NR==1 {print $5}')
  [[ $uplink =~ ^[a-zA-Z0-9_.-]+$ ]] || fail 'Cannot determine outbound interface.'
  render_firewall "$uplink"
  nft --check --file "$WORK/nftables.conf"

  publish_state

  install -d -m 700 /etc/wireguard /etc/swanctl/private /etc/swanctl/x509 /etc/swanctl/x509ca
  install -m 600 "$WORK/wg0.conf" /etc/wireguard/wg0.conf
  install -m 600 "$STATE_DIR/server.key" /etc/swanctl/private/server.key
  install -m 644 "$STATE_DIR/server.crt" /etc/swanctl/x509/server.crt
  install -m 644 "$STATE_DIR/ca.crt" /etc/swanctl/x509ca/ca.crt
  install -m 600 "$WORK/swanctl.conf" /etc/swanctl/swanctl.conf
  install -m 600 "$WORK/nftables.conf" /etc/nftables.conf
  cat > /etc/sysctl.d/90-vpn.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv6.conf.all.forwarding=0
EOF
  sysctl --system > /dev/null
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/52vpn-reboots <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
  systemctl enable nftables wg-quick@wg0 strongswan unattended-upgrades
  systemctl restart nftables
  systemctl restart wg-quick@wg0
  systemctl restart strongswan
  swanctl --load-all > /dev/null
  systemctl is-active --quiet nftables wg-quick@wg0 strongswan
  wg show wg0 > /dev/null
  swanctl --list-conns | grep -q '^ikev2:'
  printf 'VPN bootstrap complete; profiles and recovery state are in Key Vault.\n'
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
