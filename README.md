# Regional Azure VPN

A small, independent VPN appliance in each Azure region you select:

- **WireGuard**, with **20 separate ready-to-import client configurations**.
- **IKEv2/IPsec using strongSwan**, with mutual RSA certificate authentication and one shared profile for up to **20 simultaneously connected devices**. An Apple configuration profile supports native iPhone/iPad/macOS VPN clients; no VPN app, shared VPN password, PPTP, or L2TP is needed.
- Ubuntu Server **24.04 LTS**, the lowest-priced compatible **2-vCPU VM** in the deployment region by default, a 32 GiB Standard HDD OS disk, and one static Standard IPv4 address.
- Microsoft Entra SSH login with VM Administrator Login RBAC; **SSH is not exposed to the Internet**.
- Regional Key Vault for recovery keys, VPN certificates, and client profiles.
- GitHub Actions OIDC deployment. **Region is the only workflow input.**

Ubuntu is deliberate: this bootstrap relies on Ubuntu's supported WireGuard, strongSwan, nftables, unattended-upgrades, and Entra SSH packages. Azure Linux is not interchangeable with this script.

See [architecture and trust-boundary diagrams](docs/architecture.md).

To rebuild the project in another workspace, use the [Copilot recreation skill](./.github/skills/recreate-regional-vpn/SKILL.md). Run `/recreate-regional-vpn` in a Copilot chat where the skill is available, or attach the file and ask Copilot to follow it in the target workspace.

## What is deployed

`templates/main.bicep` is subscription-scoped. It creates `vpn_<region>_rg` and a regional module containing VM `vpn-<region>-vm` (with the same Linux hostname), NIC, public IP/DNS name, VNet/subnet, NSG, Key Vault, RBAC assignments, and two VM extensions (Entra login and VPN bootstrap).

Key Vault names use `vpn-<region-prefix>-<unique-suffix>`: the first 12 region characters plus a seven-character subscription/resource-group hash, for a maximum of 24 characters. For example, Denmark East produces `vpn-denmarkeast-<suffix>`. Vault names use hyphens because Azure Key Vault does not allow underscores. Resource group names use underscores throughout.

The four required Bicep parameters are `location`, `adminObjectId`, `automationObjectId`, and a **secure** `sshKey` object (`publicKey`, `privateKey`). `vmSize` is the only optional parameter. The deployment script supplies the automation object ID and generates or recovers the SSH pair; you do not manage those inputs manually.

There are **no** Log Analytics workspaces, diagnostic settings, boot diagnostics, storage accounts, Azure VPN Gateways, NAT Gateways, load balancers, Bastion instances, or public SSH rules. Logs stay on the VM.

Each region has its own keys and CA, identities, address, vault, and resource group. VM and vault names include the region; other fixed resource names are scoped to that group. Reusing the same region updates the same deployment. Different regions can deploy concurrently. This is **not** cross-region failover or a site-to-site network; only one regional VPN should be connected on a client at a time.

## First-time setup

Use an Azure **public cloud** subscription. The setup commands below are Bash (Linux, Azure Cloud Shell, or WSL), with Azure CLI, `curl`, `jq`, OpenSSH, and GitHub CLI installed.

### 1. Create a GitHub deployment identity

An administrator with permission to register Entra applications and assign Azure roles runs this once. Replace the three placeholders:

```bash
SUBSCRIPTION_ID='<subscription-id>'
REPOSITORY='<owner/repository>'
VPN_ADMIN_OBJECT_ID='<entra-user-or-group-object-id>'

az login
az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)
CLIENT_ID=$(az ad app create --display-name regional-vpn-github --query appId -o tsv)
az ad sp create --id "$CLIENT_ID" --output none
PRINCIPAL_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)

az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID" --output none
az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Role Based Access Control Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" --output none

FEDERATION=$(mktemp)
jq -n --arg subject "repo:${REPOSITORY}:environment:azure" \
  '{name:"github-azure-environment",issuer:"https://token.actions.githubusercontent.com",
    subject:$subject,audiences:["api://AzureADTokenExchange"]}' > "$FEDERATION"
az ad app federated-credential create --id "$CLIENT_ID" --parameters "@$FEDERATION" --output none
rm "$FEDERATION"
```

Subscription-level deployment and creating regional groups require broad provisioning permissions. **Contributor + RBAC Administrator can effectively grant extensive subscription access**; protect this identity and repository accordingly. This risk is accepted only for a subscription limited to VPN server deployments and the minimum global infrastructure, as recorded in the [security review](docs/SECURITY-REVIEW.md#subscription-boundary). These permissions belong to the deployment identity, not to the VPN client or VM identity.

Register resource providers once if they are not registered (registration is a subscription change):

```bash
for provider in Microsoft.Compute Microsoft.Network Microsoft.KeyVault; do
  az provider register --namespace "$provider" --wait
done
```

### 2. Configure GitHub

In the repository, create an environment named **`azure`**. Restrict its deployment branches to the trusted default branch and configure required reviewers if available. The federation trusts this environment, **not** arbitrary pull requests. Protect the default branch and workflow changes.

Set these **GitHub Actions secrets**, preferably in the `azure` environment. Repository-level Actions secrets with the same names also work. The Azure IDs are identifiers, not credentials; using secrets lets GitHub mask their values in workflow logs.

| Secret | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `$CLIENT_ID` |
| `AZURE_TENANT_ID` | `$TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `$SUBSCRIPTION_ID` |
| `VPN_ADMIN_OBJECT_ID` | Entra **object ID** of the user or group administering the VM |
| `VPN_VM_SIZE` | Optional; empty selects the cheapest compatible 2-vCPU SKU using live Azure retail prices |

Use the principal's **object ID**, not a client/application ID or email, for the VPN administrator. A group is useful for multiple administrators. No long-lived Azure client secret is needed.

### 3. Deploy a region

Run **Actions > Deploy regional VPN > Run workflow** and select an Azure region from the dropdown (default: **`denmarkeast` / Denmark East**). The choices cover common public Azure regions, including `westeurope`; subscription and SKU availability are still checked at runtime. Other regions can be used through the local deployment script or added to the workflow choices.

Denmark East creates resource group `vpn_denmarkeast_rg` and VM `vpn-denmarkeast-vm`, with its own regional public IP, region-named vault, and credentials.

Azure can advertise the region and VM SKU while an inherited **Allowed locations** policy still blocks deployment. If Denmark East fails with `RequestDisallowedByPolicy`, an authorized policy administrator must add `denmarkeast` to the applicable allowed-location list. The workflow does not modify organizational policy, create exemptions, or silently deploy to another region.

The workflow:

1. Authenticates with OIDC, checks the region and VM SKU restrictions, and queries the [Azure Retail Prices API](https://learn.microsoft.com/azure/cost-management/retail-prices/azure-retail-prices).
2. Recovers the existing regional recovery SSH key, or generates an Ed25519 pair.
3. Creates/updates the regional infrastructure, storing the recovery key **before** VM creation.
4. Waits for the VM extension to install and configure both VPNs and back up credentials using managed identity. Key Vault RBAC/service readiness is retried for up to ten minutes.
5. Reports deployment success, region, selected SKU, and estimated VM compute cost. The success log and job summary omit the hostname and vault name; both are available in Azure deployment outputs. **No client profiles or keys are uploaded as Actions artifacts.**

The workflow suppresses default Azure CLI output. Azure errors remain visible and may include resource details. For full ARM diagnostics, see **Subscriptions → your subscription → Deployments → `vpn-<region>`** in the Azure portal.

Automatic selection compares Linux pay-as-you-go rates (not Spot or reservations) for unrestricted **x64 Gen2 Trusted Launch-compatible** SKUs with exactly 2 vCPUs and at least 1 GiB of RAM. Pricing requests include only eligible SKUs, in batches of at most 10 to stay within API query-complexity and URL limits. All batches and pages are compared before selecting the cheapest rate. Transient failures, including HTTP 429 throttling, are retried up to nine times within a 15-minute retry budget per page. Backoff starts at one second and doubles after each retry; a longer `Retry-After` delay (seconds or an HTTP date) is honored as a minimum wait. The estimate is in USD per hour and per 730-hour month for VM compute only; it excludes disk, IP, vault, and network charges. If no eligible SKU can be priced or any pricing batch or page remains unavailable, automatic selection stops. With an explicit SKU, an unavailable estimate produces a warning instead.

1 GiB is a starting point for light personal use, not a throughput guarantee. If available memory runs low during updates or regular use, select a larger SKU with `VPN_VM_SIZE`. If a burstable VM regularly runs out of CPU credits, use a size with higher sustained CPU performance.

Quota, regional capacity, subscription policy, and image availability can still reject deployment. Choose another region or set `VPN_VM_SIZE` explicitly; the script never retries deployment with a different SKU or region. Deploying the Bicep template directly bypasses automatic selection and keeps its `Standard_B1s` default.

You can run the same deployment locally after signing into Azure:

```bash
export AZURE_LOCATION=denmarkeast
export VPN_ADMIN_OBJECT_ID='<entra-user-or-group-object-id>'
bash scripts/deploy.sh
```

Set `VPN_VM_SIZE` to skip automatic selection (the older local `VM_SIZE` variable is still supported). The caller needs the same provisioning permissions. Bicep grants this caller Key Vault Secrets Officer on this regional vault. Never use shell tracing (`set -x`), Azure CLI `--debug`, or print the generated parameter file: it contains the recovery private key.

## Connect clients

With the appropriate Azure access, find `vaultName` and `hostname` in the subscription deployment's **Outputs** for `vpn-<region>`, or locate the vault under `vpn_<region>_rg` in the Azure portal. The selected administrator receives **Key Vault Secrets User** on that vault. Allow time for RBAC propagation; the administrator should sign into the correct tenant.

Run the download commands outside the checkout or from its ignored `.tmp/` directory. Keep local Azure parameter files and recovery bundles out of the checkout or in `.tmp/` as well.

```bash
az login
VAULT='<vault-name-from-deployment-outputs>'
umask 077
az keyvault secret download --vault-name "$VAULT" --name wireguard-client-01-config \
  --file wireguard-01.conf --encoding utf-8 --output none
az keyvault secret download --vault-name "$VAULT" --name ikev2-client-profile \
  --file ikev2-vpn.mobileconfig --encoding utf-8 --output none
```

Treat **both files as passwords**. The IKEv2 profile embeds its client private key, its PKCS#12 password, and the private VPN CA's public certificate. The embedded password is for importing the container, **not** protection against someone who obtains the profile.

### WireGuard

There are **20 independent profiles**, stored as Key Vault secrets `wireguard-client-01-config` through `wireguard-client-20-config`. Each has a separate private key, preshared key, and tunnel addresses. Assign one profile per device; all 20 can connect simultaneously. Do not activate copies of the **same** profile concurrently.

Import `wireguard-01.conf` into an official WireGuard client. To download all profiles securely:

```bash
for number in $(seq -w 1 20); do
  az keyvault secret download --vault-name "$VAULT" --name "wireguard-client-${number}-config" \
    --file "wireguard-${number}.conf" --encoding utf-8 --output none
done
```

Keep the downloaded files private (`umask 077`). Each numbered profile is independent; assign one per device. Redeployment and recovery preserve all 20 clients' keys. There is no client-management or revocation UI.

### Certificate-authenticated IKEv2 VPN

The `ikev2-client-profile` secret downloads as `ikev2-vpn.mobileconfig` and displays as **IKEv2 VPN &lt;regional hostname&gt;**. The name describes the VPN protocol rather than a device model. The `.mobileconfig` format is for Apple devices; other IKEv2 implementations need their own certificate-import and connection configuration rather than importing this file directly.

The same profile can be installed on up to **20 concurrently connected devices**, including devices behind the same NAT/router. Each connection receives its own IPv4 and IPv6 tunnel addresses; the 21st connection is refused until a slot is released. Stale sessions after an abrupt disconnect can temporarily consume slots until dead-peer detection clears them. This is a connection/address-pool limit, not a count of installations or a guarantee of VPN throughput on the small VM.

All copies share the same private key and `vpn-client` identity. There is **no individual device revocation or reliable per-person attribution**; compromise of one copy requires replacing the shared credentials on every device. WireGuard instead supplies **20 separate configurations, each for one concurrent device**.

1. Transfer `ikev2-vpn.mobileconfig` securely to the device, for example by AirDrop from a trusted Mac or through your managed device distribution system. Do **not** publish it at a public URL, commit it, or send it through untrusted email.
2. Install the downloaded profile in **Settings > General > VPN & Device Management** and review the hostname and certificates. An unsigned profile warning is expected: this repository does not have a profile-signing identity.
3. Enable the named VPN under Settings. No App Store VPN client is needed. Use a current, supported iOS release.

The profile installs a private CA for this VPN. Do not separately enable full website/TLS trust for that CA. Remove the profile when no longer needed. The client and server authenticate with certificates; IKE/ESP use AES-256, SHA-256, and DH group 14 with PFS. The legacy 3DES **PKCS#12 file encoding** required by Apple's importer is not a negotiated VPN cipher.

Both clients request a full tunnel and use Cloudflare DNS through it. The service provides **IPv4 Internet egress only**. IPv6 is captured by the profiles but intentionally discarded at the server to avoid ordinary IPv6 bypass. The iPhone profile also requests `IncludeAllNetworks`. This is not a supervised iOS Always On deployment or an unconditional kill switch: Apple excludes some system traffic, and traffic can bypass when a user disconnects the VPN. Verify your actual device as described below.

## Administrator access with Entra ID

First connect either VPN from the administrator's computer. The VM's WireGuard address `10.77.0.1` is reachable through either VPN:

```bash
az login
az extension add --name ssh
az ssh vm --ip 10.77.0.1
```

The VM has a system-assigned identity, the `AADSSHLoginForLinux` extension, and a VM-scoped **Virtual Machine Administrator Login** assignment for the selected Entra principal. This grants `sudo`; subscription Contributor/Owner alone does **not** grant Entra OS login. Tenant/Conditional Access policies still apply. The administrator also needs outbound access to Microsoft login endpoints.

The key-based `vpnadmin` account is only a recovery path. Its key is the `admin-ssh-private-key` vault secret, and it also requires VPN connectivity. If the VPN is down, an appropriately authorized Azure operator can use **VM Run Command** rather than opening public SSH. Giving someone control-plane VM Run Command access effectively gives them root; keep that separate from ordinary VPN membership.

## Operations, recovery, and cost

- **Persistent state:** `/etc/vpn-state` is root-only. `vpn-state` in Key Vault is its base64-encoded compressed recovery archive, containing the CA, server/client private keys and certificates, PKCS#12 identity/password, all 20 WireGuard clients' keys in `wireguard-clients.json`, and endpoint. The numbered WireGuard profiles, `ikev2-client-profile`, and `admin-ssh-private-key` are separate secrets for convenient retrieval.
- **Redeploy:** rerun the workflow for the same region. Credentials are reused. The extension runs when bootstrap content changes or when recreated; an unchanged extension is not a periodic health check. An unavailable vault is a hard failure, never an instruction to rotate keys. Conflicting local/vault state also fails for operator investigation.
- **Changing administrators:** incremental ARM deployments add assignments for the new principal but do not revoke the previous principal's assignments. Explicitly remove the former administrator's vault/VM roles, and rotate client credentials if that administrator must no longer have VPN access.
- **Lost VM/disk:** keep the regional vault and public IP. Recreate the VM with the same template; bootstrap restores `vpn-state`. Keep the same FQDN because certificates bind to it. Do not restore one region's archive into a different region.
- **Deletion settings:** purge protection is **disabled** by omitting `enablePurgeProtection`; Azure rejects an explicit `false` even for new vaults. Azure Key Vault enables soft delete on new vaults and does not allow disabling it; retention is set to the minimum **7 days**. An appropriately authorized operator can immediately purge a soft-deleted vault rather than wait for retention. See [Azure soft-delete behavior](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview#soft-delete-behavior). These settings cannot remove purge protection from older vaults that already enabled it.
- **Back up independently:** soft delete is not an independent backup, and a purge is irreversible. Export `vpn-state` and `admin-ssh-private-key` to an encrypted, access-controlled backup if you require disaster recovery. Anyone with `vpn-state` can impersonate this VPN and issue certificates.
- **Certificates:** CA lifetime is 10 years, server/client lifetime is 825 days. Bootstrap rejects certificates with less than 30 days remaining. Automatic certificate renewal, multi-user issuance, and individual revocation are not included. Before expiry or after compromise, provision a replacement region with fresh credentials, migrate clients, then retire the old region. Do not delete the archive expecting an automatic safe rotation.
- **Updates:** unattended Ubuntu security updates are enabled. Reboots occur at **04:00 VM local time (normally UTC)** when required, temporarily interrupting the VPN. Kernel updates take effect after reboot. Review locally stored logs and update non-security packages during planned maintenance.
- **OS disk:** [the regional template](templates/regional.bicep) explicitly provisions a 32 GiB managed Standard HDD (`Standard_LRS`) for Ubuntu, packages, and local logs. This is independent of the VM's RAM and is not included in the compute estimate.
- **Costs:** recurring charges are the small VM, 32 GiB Standard HDD disk, Standard public IPv4, Key Vault operations, and Internet egress. Consult the [Azure calculator](https://azure.microsoft.com/pricing/calculator/) for your region, currency, and bandwidth; sustained VPN traffic can make bandwidth the dominant cost. A burstable SKU can have limited sustained throughput, and each region runs a single VM without redundancy.
- **Stop versus delete:** deallocating stops compute charges but disk and public IP remain billable. Delete `vpn_<region>_rg` only when intentionally retiring that region and after saving any required recovery material. Its vault remains soft-deleted until purged or retention expires; purge it manually before reusing its deterministic name, or recover it deliberately. Deployment does not automatically purge or recover deleted vaults.
- **State format:** deployments create and restore only the current complete state format. They do not convert older layouts, reconcile incomplete credentials, rename resources, or search old resource groups. Handle any required conversions and resource replacements manually.

### Troubleshooting

On the VM (Entra SSH or Azure Run Command):

```bash
sudo systemctl status wg-quick@wg0 strongswan nftables --no-pager
sudo wg show
sudo swanctl --list-conns
sudo swanctl --list-sas
sudo journalctl -u strongswan -u wg-quick@wg0 --since '30 minutes ago' --no-pager
```

Bootstrap output is in `/var/log/azure/custom-script/handler.log` and the Custom Script extension's status/output files. Do not publish these logs without reviewing them. Script output does not intentionally contain secrets.

If bootstrap failed, fix the reported cause first. An Azure operator with VM Run Command rights can retry the **current checked-out bootstrap** without opening SSH:

```bash
RG=vpn_denmarkeast_rg
VAULT='<regional-vault-name>'
HOST='<regional-hostname-from-public-ip>'
VM=$(az vm list --resource-group "$RG" --query '[0].name' -o tsv)
az vm run-command invoke --resource-group "$RG" --name "$VM" \
  --command-id RunShellScript \
  --scripts "export VPN_VAULT='$VAULT' VPN_HOST='$HOST'; $(cat scripts/bootstrap.sh)" \
  --query 'value[].message' -o tsv
```

Only use trusted repository content. Concurrent bootstraps are rejected by a host lock. If the original extension is still running, wait for it to finish first.

## Validation

```bash
az bicep build --file templates/main.bicep --outfile /tmp/vpn.json
shellcheck -x scripts/*.sh tests/*.sh
bash tests/bootstrap.sh
bash tests/deploy.sh
bash tests/vault.sh
docker build --file tests/Dockerfile --tag vpn-validation .
docker run --rm --cap-add NET_ADMIN vpn-validation
bash tests/shared-profile.sh
```

The portable tests need Bash, OpenSSH, OpenSSL 3 with its legacy provider, `jq`, and Python 3's standard library. They verify actual certificate chains and PKCS#12 import, parse the Apple plist, check 20 distinct WireGuard peers, derive and verify VPN/Azure address-space separation (including deliberate collision rejection), exercise complete-state recovery and refusal to replace keys on vault errors/conflicts, check Key Vault HTTP/error/size boundaries, and test fresh/repeated Denmark East and West Europe deployment with a mocked Azure CLI. The isolated Linux container additionally loads actual strongSwan credentials/configuration, applies nftables, and verifies all 20 WireGuard peers complete kernel handshakes. The shared-profile test starts isolated containers with 21 clients using the same certificate/identity behind one NAT, verifies 20 connections with distinct leases and working traffic, rejects the 21st, and tests reuse of a released slot. These need a Linux Docker host with WireGuard support. The validation workflow runs them on Ubuntu.

These are not a substitute for a live deployment test. After deployment, test **both** protocols from an external network:

1. Verify the public IPv4 is the regional VM's address and DNS requests traverse the tunnel.
2. Verify IPv6 Internet access is blocked instead of leaking to the local ISP.
3. Check native iPhone connection, sleep/wake, Wi-Fi-to-cellular roaming, and reconnect.
4. Check Entra SSH through the VPN and that TCP/22 is closed from the Internet.
5. Reboot the VM and reconnect; redeploy the region and ensure the original profiles still work.

## References

- [Microsoft Entra SSH for Linux VMs](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux)
- [strongSwan Apple IKEv2 profile interoperability](https://docs.strongswan.org/docs/latest/interop/appleIkev2Profile.html)
- [Apple IKEv2 device management settings](https://support.apple.com/guide/deployment/dep4ce9487d/web)
- [GitHub OIDC with Azure](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [Azure Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
