FROM rust:1.97.1-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iptables nftables tcpdump python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
CMD ["bash"]
