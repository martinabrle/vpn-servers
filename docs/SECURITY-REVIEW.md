# Security review and accepted risks

**Status:** The findings below have been reviewed and accepted for the current deployment model. They have not been remediated.

**Review scope:** These findings come from a static review of the Azure templates, provisioning and bootstrap scripts, workflows, and tests conducted on the current repository state.

## Subscription boundary

The workflow creates regional resource groups as part of deployment, so it cannot use permissions scoped only to pre-existing resource groups. The current workflow retains **Contributor** and **Role Based Access Control Administrator** at subscription scope. This combination can grant broad access throughout the subscription.

This risk is accepted only for a subscription that contains **VPN server deployments and the minimum global infrastructure**. Do not place unrelated workloads in this subscription. This boundary limits what is exposed but does not reduce the workflow identity's privileges within the subscription. Follow the [GitHub environment and branch protection guidance](../README.md#2-configure-github). Revisit the decision if the subscription's workload scope expands or resource-group provisioning can be separated from routine VPN deployments.

## Findings

The file links point to the corresponding files in this repository, not to the original review snapshot. All findings in this table are accepted under the scope above.

| # | Severity | File | Risk | Confidence |
|---|----------|------|------|------------|
| 1 | HIGH | [README.md](../README.md) | Compromise of the GitHub deployment identity can affect any resource in the subscription, including its global infrastructure. | 10/10 |
| 2 | MEDIUM | [deploy.sh](../scripts/deploy.sh), [regional.bicep](../templates/regional.bicep) | A failed resource-group lookup or missing recovery secret can trigger new SSH key generation for an existing VM. The vault is updated before the VM, so the stored key can stop matching the VM's recovery account. | 9/10 |
| 3 | MEDIUM | [bootstrap.sh](../scripts/bootstrap.sh) | Restore installs the archive before checking certificates. If validation then fails, the bad local state can cause a corrected backup to be rejected on retry. | 10/10 |
| 4 | MEDIUM | [bootstrap.sh](../scripts/bootstrap.sh) | On Ubuntu, restarting nftables removes the active rules before loading the replacement. Existing VPN tunnels can remain active without host filters if the load fails. | 9/10 |
| 5 | MEDIUM | [bootstrap.sh](../scripts/bootstrap.sh) | WireGuard key checks do not enforce a single value before rendering privileged configuration. This matters when restoring a modified backup on a VM without existing local state. | 9/10 |
| 6 | MEDIUM | [deploy.sh](../scripts/deploy.sh), [regional.bicep](../templates/regional.bicep) | A new deployment identity cannot redeploy an existing vault without secret-list access. The script attempts to list secrets before the template grants the caller access. | 10/10 |
| 7 | MEDIUM | [regional.bicep](../templates/regional.bicep), [vault-access.bicep](../templates/vault-access.bicep) | The VM identity can delete recovery secrets, purge protection is disabled for new vaults, and deployment does not create an independent backup. A VM compromise can put both local and vault recovery copies at risk. | 10/10 |
| 8 | MEDIUM | [regional.bicep](../templates/regional.bicep) | Changing the administrator adds new role assignments but does not revoke the former administrator's vault or VM access. Offboarding requires explicit role removal and, where needed, credential rotation. | 10/10 |
| 9 | MEDIUM | [linux.sh](../tests/linux.sh), [shared-profile.sh](../tests/shared-profile.sh) | The IKEv2 traffic test reaches the VPN server itself, and the WireGuard test checks handshakes only. Neither verifies end-to-end IPv4 forwarding and NAT or checks for client-side IPv6 leakage. | 10/10 |
| 10 | LOW | [bootstrap.sh](../scripts/bootstrap.sh) | Client private and preshared keys appear in process arguments during generation and can be visible to local processes. | 10/10 |

## When to revisit

- **Identity or administrator changes:** review deployment and vault access before a handover, and confirm old role assignments are removed during offboarding.
- **Recovery or backup changes:** verify the stored SSH key still matches the guest and that a restore uses the original VPN credentials. Keep any independent backup encrypted and separately access-controlled.
- **Bootstrap, firewall, or client changes:** follow the [client validation checklist](../README.md#validation) after deployment. Successful extension provisioning, a handshake, or a ping to the VM is not proof of working Internet egress or of IPv6 leak prevention.
