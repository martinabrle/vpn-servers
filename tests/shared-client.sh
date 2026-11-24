#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
: "${SERVER_IP:?Set SERVER_IP}"
: "${ROUTER_IP:?Set ROUTER_IP}"
ip route replace default via "$ROUTER_IP"
install -d /etc/swanctl/private /etc/swanctl/x509 /etc/swanctl/x509ca
install -m 600 /shared/state/client.key /etc/swanctl/private/client.key
install -m 644 /shared/state/client.crt /etc/swanctl/x509/client.crt
install -m 644 /shared/state/ca.crt /etc/swanctl/x509ca/ca.crt
cat > /etc/swanctl/swanctl.conf <<EOF
connections {
  shared {
    version = 2
    remote_addrs = ${SERVER_IP}
    vips = 0.0.0.0, ::
    proposals = aes256-sha256-modp2048
    encap = yes
    mobike = yes
    local {
      auth = pubkey
      id = vpn-client
      certs = client.crt
    }
    remote {
      auth = pubkey
      id = vpn-test.denmarkeast.cloudapp.azure.com
      cacerts = ca.crt
    }
    children {
      internet {
        local_ts = dynamic
        remote_ts = 0.0.0.0/0, ::/0
        esp_proposals = aes256-sha256-modp2048
      }
    }
  }
}
EOF
/usr/sbin/charon-systemd > /run/shared-charon.log 2>&1 &
charon_pid=$!
trap 'kill "$charon_pid"' EXIT
for ((attempt=0; attempt<20; attempt++)); do
  if [[ -S /var/run/charon.vici ]]; then break; fi
  sleep 1
done
swanctl --load-all
touch /run/shared-ready
wait "$charon_pid"
