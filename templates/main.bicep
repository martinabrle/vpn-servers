targetScope = 'subscription'

@description('Azure region short name, for example denmarkeast. One independent resource group per region.')
param location string

@description('Object ID of the Entra user or group allowed to administer the VM and read VPN profiles.')
param adminObjectId string

@secure()
@description('Recovery SSH key pair. The private key is written only to the regional Key Vault.')
param sshKey {
  publicKey: string
  privateKey: string
}

@description('Object ID of the GitHub OIDC service principal. Granted secret access only in this regional vault.')
param automationObjectId string

@description('Low-cost 2-vCPU burstable default. Override if unavailable in the selected region or more throughput is needed.')
param vmSize string = 'Standard_B2ats_v2'

resource regionalGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'vpn_${location}_rg'
  location: location
  tags: {
    workload: 'personal-vpn'
    region: location
  }
}

module regional 'regional.bicep' = {
  scope: regionalGroup
  params: {
    location: location
    adminObjectId: adminObjectId
    automationObjectId: automationObjectId
    sshKey: sshKey
    vmSize: vmSize
  }
}

output resourceGroupName string = regionalGroup.name
output vaultName string = regional.outputs.vaultName
output hostname string = regional.outputs.hostname
output vmName string = regional.outputs.vmName
