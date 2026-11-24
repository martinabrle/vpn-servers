param location string = resourceGroup().location
param adminObjectId string
param automationObjectId string
@secure()
param sshKey {
  publicKey: string
  privateKey: string
}
param vmSize string

var suffix = uniqueString(subscription().id, resourceGroup().id)
var vaultName = 'vpn-${take(location, 12)}-${take(suffix, 7)}'
var vmName = 'vpn-${location}-vm'
var tags = resourceGroup().tags
var secretsOfficer = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
var secretsUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    // Azure requires soft delete. Omit enablePurgeProtection: false is rejected even on new vaults.
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'vpn-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'vpn-udp'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '500'
            '4500'
            '51820'
          ]
        }
      }
      {
        name: 'deny-other-inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vpn-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.76.0.0/24'
      ]
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: 'vpn'
  properties: {
    addressPrefix: '10.76.0.0/24'
    defaultOutboundAccess: false
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'vpn-ip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: 'vpn-${suffix}'
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'vpn-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  dependsOn: [
    recoveryKey
  ]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 32
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: vmName
      #disable-next-line adminusername-should-not-be-literal // Fixed recovery account, not an operator identity.
      adminUsername: 'vpnadmin'
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/vpnadmin/.ssh/authorized_keys'
              keyData: sshKey.publicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

// A module makes the new system identity available when calculating the assignment name after VM recreation.
module vmSecrets 'vault-access.bicep' = {
  params: {
    vaultName: vault.name
    principalId: vm.identity.principalId
  }
}

resource automationSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, automationObjectId, secretsOfficer)
  scope: vault
  properties: {
    roleDefinitionId: secretsOfficer
    principalId: automationObjectId
    principalType: 'ServicePrincipal'
  }
}

resource recoveryKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'admin-ssh-private-key'
  dependsOn: [
    automationSecrets
  ]
  properties: {
    value: sshKey.privateKey
    contentType: 'application/x-pem-file'
  }
}

resource adminSecrets 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, adminObjectId, secretsUser)
  scope: vault
  properties: {
    roleDefinitionId: secretsUser
    principalId: adminObjectId
  }
}

resource adminLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, adminObjectId, 'admin-login')
  scope: vm
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
    principalId: adminObjectId
  }
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

var bootstrap = loadTextContent('../scripts/bootstrap.sh')

resource vpnBootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'vpn-bootstrap'
  location: location
  dependsOn: [
    vmSecrets
    entraLogin
  ]
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: uniqueString(bootstrap, publicIp.properties.dnsSettings.fqdn, vault.id)
    protectedSettings: {
      commandToExecute: 'VPN_VAULT=${vault.name} VPN_HOST=${publicIp.properties.dnsSettings.fqdn} bash -c "printf %s ${base64(bootstrap)} | base64 -d | bash"'
    }
  }
}

output vaultName string = vault.name
output hostname string = publicIp.properties.dnsSettings.fqdn
output vmName string = vm.name
