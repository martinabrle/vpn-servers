param vaultName string
param principalId string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, principalId, roleId)
  properties: {
    roleDefinitionId: roleId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
