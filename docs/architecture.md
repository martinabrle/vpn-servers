# Architecture

## One independent stack per region

Denmark East (`denmarkeast`) is the default workflow selection: its resource group is `vpn_denmarkeast_rg` and its VM is `vpn-denmarkeast-vm`. Other selected regions remain independent stacks.

```mermaid
flowchart TB
    gh["GitHub Actions<br/>protected azure environment"]
    entra["Microsoft Entra ID<br/>OIDC and ephemeral SSH certificates"]
    admin["Administrator computer<br/>VPN connected"]
    wg["20 WireGuard clients<br/>separate keys and addresses"]
    ios["Native VPN clients<br/>certificate-authenticated IKEv2"]
    internet["IPv4 Internet"]
    gh -->|"OIDC federation; no client secret"| entra

    subgraph region["vpn_REGION_rg (repeated independently per region)"]
        pip["Static Standard IPv4<br/>regional Azure DNS name"]
        nsg["NSG<br/>UDP 51820, 500, 4500 only<br/>deny all other inbound"]
        vm["vpn-REGION-vm<br/>Ubuntu 24.04 LTS<br/>WireGuard + strongSwan<br/>nftables forwarding + IPv4 NAT<br/>Entra SSH extension"]
        disk["32 GiB Standard HDD<br/>root-only persistent state"]
        kv["Region-named Key Vault<br/>RBAC, required soft delete<br/>purge protection disabled"]
        pip --> nsg --> vm
        vm --- disk
        vm -->|"system-assigned identity<br/>backup / restore secrets over HTTPS"| kv
    end

    gh -->|"ARM/Bicep<br/>create resources and scoped RBAC"| region
    wg -->|"UDP 51820"| pip
    ios -->|"UDP 500 / 4500<br/>IPsec forced through NAT-T"| pip
    admin -->|"Entra SSH inside either VPN<br/>10.77.0.1:22"| vm
    entra -.->|"VM Administrator Login RBAC"| vm
    vm -->|"masqueraded client traffic"| internet
    admin -->|"Secrets User<br/>download client profiles"| kv
```

The Standard public IP supplies explicit outbound connectivity even though default subnet outbound access is disabled. IP forwarding is enabled on both the NIC and in Linux. No Azure route table is needed for remote-access clients: their traffic is decrypted and NATed on the appliance.

The host firewall permits SSH only from authenticated VPN traffic. IKEv2 SSH/forwarding rules require an inbound IPsec policy (reqid 1), not just a source address. VPN clients cannot forward to Azure metadata, Azure platform DNS, or private network ranges; this appliance is for Internet access, not lateral access to Azure workloads. IPv6 forwarding is denied.

| Network | Purpose |
| --- | --- |
| `10.76.0.0/24` | Azure subnet, one NIC |
| `10.77.0.0/24`, `fd77::/64` | WireGuard; server `.1` / `::1`, 20 clients `.2`-`.21` / `::2`-`::15` (hexadecimal) |
| `10.78.0.1`-`10.78.0.20`, `fd78::1`-`fd78::14` | 20 IKEv2 client leases per address family (IPv6 endpoint `14` is hexadecimal) |

These allocations do not overlap. The Azure subnet (`10.76.0.0/24`), WireGuard subnet (`10.77.0.0/24`), and IKEv2 IPv4 pool in `10.78.0.0/24` have different third octets. WireGuard's `fd77::/64` and IKEv2's `fd78::1`-`fd78::14` also have different IPv6 prefixes. WireGuard's 20 peers use distinct host addresses and exclude its server address; IKEv2 leases a separate address to each active connection.

Both kinds of client intentionally request default routes (`0.0.0.0/0`, `::/0`) for full-tunnel operation. These are client routing policies, not overlapping server-side address allocations. WireGuard's server peer `AllowedIPs` are disjoint host prefixes, while strongSwan installs IPsec policies for the separate IKEv2 leases.

The portable regression tests derive these ranges from rendered server/client configurations and the Bicep Azure subnet. They verify IPv4/IPv6 separation, address containment, uniqueness, server exclusion, peer bindings, and exactly 20 leases per IKEv2 pool. The same validator must reject deliberately colliding IPv4/IPv6 pools and duplicate WireGuard client addresses. Linux tests additionally exercise all 20 WireGuard handshakes and 20 simultaneous IKEv2 tunnels with traffic.

IKEv2 permits concurrent connections with the shared `vpn-client` identity and ignores identity-based replacement requests from other copies of the profile. The 20-address pools bound simultaneous client leases; devices behind one NAT receive separate leases based on their translated endpoints. A copied profile is a shared credential, not an individually revocable device identity.

WireGuard provisions 20 distinct peers, each with a separate private key, preshared key, and IPv4/IPv6 address. Key Vault stores only numbered profile secrets `wireguard-client-01-config` through `wireguard-client-20-config`. The recovery archive includes all 20 peer credentials in the required `wireguard-clients.json`. Recovery uses the complete current state; missing or conflicting credentials cause a failure, never automatic conversion or replacement.

The device-neutral `ikev2-client-profile` secret contains an Apple configuration profile named `ikev2-vpn.mobileconfig`, displayed as **IKEv2 VPN &lt;regional hostname&gt;**. The file format is Apple-specific even though IKEv2 is not.

VM resource and Linux host names include the region (`vpn-<region>-vm`). Resource groups use underscore delimiters (`vpn_<region>_rg`). Vault names combine `vpn-`, the first 12 region characters, and a seven-character uniqueness suffix, remaining within Azure's 24-character limit. Key Vault requires hyphens rather than underscores. There are no resource-renaming or credential-format conversion paths.

Purge protection is disabled for new vaults. Azure requires soft delete, so the template uses its minimum seven-day retention; an authorized operator can purge a deleted vault immediately. Deployment never purges, recovers, or replaces an old vault automatically.

This proves separation inside one appliance, not against every possible client LAN. Avoid overlapping client LAN ranges. Address spaces are intentionally fixed to minimize parameters; change the Bicep/bootstrap together if your environment requires other ranges. Regions are not peered and intentionally reuse these ranges; do not activate multiple regional VPNs on the same client at once.

## Provisioning and secret lifecycle

```mermaid
sequenceDiagram
    actor Operator
    participant GH as GitHub Actions
    participant ARM as Azure Resource Manager
    participant KV as Regional Key Vault
    participant VM as Ubuntu VM / bootstrap
    Operator->>GH: Run workflow (region)
    GH->>GH: OIDC sign-in and caller object ID
    opt Regional recovery SSH key already exists
        GH->>KV: Retrieve existing recovery key
    end
    GH->>GH: Otherwise generate temporary SSH pair
    GH->>ARM: Bicep with secure SSH key parameter
    ARM->>KV: Store recovery SSH private key
    ARM->>VM: Create VM, identity, Entra extension and scoped RBAC
    ARM->>VM: Run bootstrap extension (no embedded VPN secrets)
    VM->>KV: Managed identity GET vpn-state
    alt Existing backup
        KV-->>VM: Restore original keys, certificates, endpoint
    else Secret is absent (HTTP 404)
        VM->>VM: Reuse local state or generate new keys and certificates
    else Vault/authentication/service error
        VM-->>ARM: Fail, do not replace credentials
    end
    VM->>KV: Persist recovery archive and client profiles
    VM->>VM: Apply firewall, start and verify both services
    VM-->>ARM: Extension succeeds
    ARM-->>GH: Non-secret outputs
    GH-->>Operator: Deployment status, region, VM size, estimated cost
    Operator->>ARM: Look up hostname and vault name in deployment outputs
    Operator->>KV: Download profiles using Entra identity
```

Secrets are generated on the VM except the recovery SSH key, which exists temporarily on the GitHub runner and is passed as a secure ARM parameter. Runner files use mode 0600 and are removed on exit. The VM keeps root-only operational credentials on its encrypted-at-rest managed disk. Key Vault stores the recovery material; neither ARM outputs nor GitHub artifacts contain credentials.

The VM and workflow identity have **Secrets Officer only on this vault**. The administrator has **Secrets User on this vault** and **VM Administrator Login on this VM**. All of these are high-trust identities: the vault contains CA and client private keys, and the workflow can execute root code on the VM. Key Vault's public HTTPS endpoint is enabled to avoid Private Endpoint/DNS costs; access is authenticated with Entra RBAC, not anonymous or shared-key access.

This design deliberately favors low cost over high availability and enterprise PKI separation. A compromised VM can read its regional recovery credentials and CA key. There is no offline CA, HSM, centralized log collection, automated VPN credential rotation, or availability SLA for a single VM. Unattended security-update reboots briefly interrupt service.
