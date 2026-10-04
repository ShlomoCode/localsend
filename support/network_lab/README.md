# LocalSend CLI network lab

This lab runs the compiled CLI as real Linux processes in disposable network namespaces. Each JSON scenario declares hosts, L2 segments, addresses, routes, multicast policy, and expected discovery and transfer outcomes. Root namespace bridges connect veth pairs; the CLI runs in each host namespace with its own configuration and identity. The tests compare SHA-256 of the sent and received file and check structured CLI results. A failed expectation exits nonzero. The suite keeps command and CLI logs and packet captures, and records addresses, routes, sockets, and firewall rules on failure. Namespace and bridge names have a random prefix and are removed even after a failure.

The runner needs root privileges, `iproute2` (`ip`, `ss`), `iptables`, `ip6tables`, `tcpdump`, `python3`, and a Linux kernel with network namespace and veth support. CI installs these on Ubuntu. To reproduce locally in a privileged Docker container, from the repository root:

```sh
docker build -f support/network_lab/Dockerfile -t localsend-network-lab support/network_lab
docker run --rm --privileged -v "$PWD:/src" -w /src localsend-network-lab \
  bash -lc 'CARGO_TARGET_DIR=/tmp/localsend-target cargo build -p localsend-cli --locked && python3 support/network_lab/run.py --binary /tmp/localsend-target/debug/localsend-cli --scenario all --artifacts /src/artifacts/network-lab'
```

`--privileged` is needed to create network namespaces, veth pairs, bridges, and firewall rules inside the container. The build target is kept in Linux `/tmp` so a macOS host's `target/` is never reused. The source mount is writable for the lab artifacts; alternatively mount a separate output directory and pass it to `--artifacts`. For a Linux host without Docker:

```sh
cargo build -p localsend-cli --locked
sudo python3 support/network_lab/run.py --binary target/debug/localsend-cli --scenario all --artifacts artifacts/network-lab
```

Use `--scenario smoke` for same-LAN cases and `--scenario full` for all other scenarios. A single scenario can be selected by its JSON key. The suite currently asserts these stable outcomes:

| Scenario | Expected behavior |
| --- | --- |
| `lan` | Same-LAN multicast discovery and bidirectional transfer. |
| `blocked_multicast` | IPv4/IPv6 multicast is dropped; HTTP `/24` scan still discovers a same-LAN peer. |
| `routed_vlans` | 802.1Q VLAN 101 and 102 reach each other through a router; fresh alias discovery is unavailable across isolated L2 domains. |
| `large_subnet` | Multicast is dropped on a `/16`; discovery does not scan the other `/24`, but direct IP transfer works. |
| `large_subnet_multicast` | The same cross-`/24` shape discovers successfully when multicast works; this controls the blocked case. |
| `dual_stack` | Discovery and transfer work on a dual-stack LAN; direct IPv6 global and scoped link-local targets also transfer. |
| `ipv6_only` | Discovery and direct transfers work with only IPv6 global and link-local addresses. |
| `multi_interface` | A host on LAN and a separate VPN-like L2 segment discovers and transfers to peers on both interfaces. The second segment models VPN routing; it does not create an encrypted tunnel. |
| `double_router` | Known-IP transfer crosses two routers; fresh alias discovery does not cross the L2 boundaries. |
| `nat_edge` | A private peer can send through masquerade; a peer on the outside cannot initiate a transfer to its private address. |
| `composite` | A multihomed edge reaches its LAN and remote routed peer through two routers; a routed guest subnet stays undiscovered and is blocked by a router forwarding rule. |

The composite scenario also runs a persistent session with `serve --stdio` on all four endpoints at once. The harness answers each `receive_request` through the CLI's JSON-line protocol, checks the initial discovery snapshot, then sends to the local peer by alias, to the remote peer by IP in both directions, and to the ACL-isolated guest as an expected failure. All four processes stay online through these checks; final status must be idle. This supplements the pairwise checks with a live multi-peer topology.

The distinction between discovery and reachability is deliberate. The core scans only local `/24` addresses after multicast and known addresses. The CLI config starts fresh in each scenario, so a routed peer has no remembered address. This lab does not simulate packet loss, churn, or fuzzing. It exercises stable network layouts and records observable behavior of real CLI instances. Logs may contain local ephemeral identity details; treat downloaded CI artifacts as diagnostic data.
