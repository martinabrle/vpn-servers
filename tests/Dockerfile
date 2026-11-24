FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    wireguard-tools strongswan-swanctl charon-systemd libstrongswan-standard-plugins \
    libcharon-extra-plugins openssl jq nftables netbase iproute2 iputils-ping ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /validation
COPY scripts/bootstrap.sh scripts/bootstrap.sh
COPY tests/linux.sh tests/linux.sh
COPY tests/shared-client.sh tests/shared-client.sh
CMD ["bash", "tests/linux.sh"]
