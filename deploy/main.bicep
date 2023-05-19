// Define the parameter for location
@description('Location in which resources will be created')
param location string = resourceGroup().location
param email string
param publisherName string
param suffix string
param openAiLocation string = resourceGroup().location
param customSubDomainName string
param openai_model_deployments array = []

@description('The resource ID for an existing Log Analytics workspace')
param log_analytics_workspace_id string

var apim_name = 'apim-openai-${suffix}'

// Network Security Group for the App Gateway subnet
resource nsggateway 'Microsoft.Network/networkSecurityGroups@2020-11-01' = {
  name: 'nsg-gateway'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowGatewayManager'
        properties: {
          description: 'Allow GatewayManager'
          priority: 2702
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
    ]
  }
}        

// Virtual Network for the App Gateway subnet
resource vnetgateway 'Microsoft.Network/virtualNetworks@2020-11-01' = {
  name: 'vnet-gateway'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-gateway'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsggateway.id }
        }
      }
    ]  
  }
}

// Subnet that for the Application Gateway
resource snetgateway 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' existing = {
  parent: vnetgateway
  name: 'snet-gateway'
}

// Network Security Group for the API Management subnet
resource nsgapi 'Microsoft.Network/networkSecurityGroups@2020-11-01' = {
  name: 'nsg-api'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-3443-Inbound'
        properties: {
          priority: 1010
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3443'
        }
      }
      {
        name: 'Allow-443-Inbound'
        properties: {
          priority: 1020
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-3443-Outbound'
        properties: {
          priority: 1030
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3443'
        }
      }
    ]
  }
}

// Virtual Network for workload
resource vnetapp 'Microsoft.Network/virtualNetworks@2020-11-01' = {
  name: 'vnet-app'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.1.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-api'
        properties: {
          addressPrefix: '10.1.1.0/24'
          networkSecurityGroup: { id: nsgapi.id }
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'
              locations: [
                '*'
              ]
            }
          ]
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-endpoints'
        properties: {
          addressPrefix: '10.1.2.0/24'
          networkSecurityGroup: { id: nsgapi.id }
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'
              locations: [
                '*'
              ]
            }
          ]
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// Subnet for API Management
resource snetapi 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' existing = {
  parent: vnetapp
  name: 'snet-api'
}

// Subnet for Private Links
resource snetendpoints 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' existing = {
  parent: vnetapp
  name: 'snet-endpoints'
}

resource azure_api_net 'Microsoft.Network/privateDnsZones@2018-09-01' = {
  name: 'azure-api.net'
  location: 'global'
  properties: {}
  dependsOn: [
    apim
    vnetapp
  ]
}

resource azure_api_net_apim_name 'Microsoft.Network/privateDnsZones/A@2018-09-01' = if (true) {
  parent: azure_api_net
  name: apim_name
  properties: {
    ttl: 36000
    aRecords: [
      {
        ipv4Address: apim.properties.privateIPAddresses[0]
      }
    ]
  }
}

resource azure_api_net_vnet_dns_link_name 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: azure_api_net
  name: 'openai-vnet-dns-link'
  location: 'global'
  properties: {
    registrationEnabled: true
    virtualNetwork: {
      id: vnetapp.id
    }
  }
}

// Application Gateway Public IP
resource publicIPAddress 'Microsoft.Network/publicIPAddresses@2021-08-01' = {
  name: 'pip-gateway-openai'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: customSubDomainName
    }
  }
}

// Craete Application Gateway
resource appgateway 'Microsoft.Network/applicationGateways@2021-08-01' = {
  name: 'gateway-openai'
  location: location
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: snetgateway.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIPAddress.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'http'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'gatewayBackEnd'
        properties: {
          backendAddresses: [
            {
              fqdn: '${apim_name}.azure-api.net'
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'appGatewayBackendHttpSettings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          hostName: '${apim_name}.azure-api.net'
          pickHostNameFromBackendAddress: false
          requestTimeout: 20
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', 'gateway-openai', 'apim-gateway-probe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'apim-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontEndIPConfigurations', 'gateway-openai', 'appGatewayFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontEndPorts', 'gateway-openai', 'http')
          }
          protocol: 'Http'
          requireServerNameIndication: false
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'apim-routing-rule'
        properties: {
          ruleType: 'Basic'
          priority: 1
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', 'gateway-openai', 'apim-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'gateway-openai', 'gatewayBackEnd')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'gateway-openai', 'appGatewayBackendHttpSettings')
          }
        }
      }
    ]
    probes: [
      {
        name: 'apim-gateway-probe'
        properties: {
          protocol: 'Https'
          host: '${apim_name}.azure-api.net'
          port: 443
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 120
          unhealthyThreshold: 8
          pickHostNameFromBackendHttpSettings: false
          minServers: 0
        }
      }
    ]
    webApplicationFirewallConfiguration: {
      enabled: true
      firewallMode: 'Detection'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
  }
  dependsOn: [
    app_insights
    vnetapp
    azure_api_net
  ]
}


// Create App Insights
resource app_insights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: 'insights-openai-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: log_analytics_workspace_id
  }
}

// Create API Management
resource apim 'Microsoft.ApiManagement/service@2020-12-01' = {
  name: apim_name
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: email
    publisherName: publisherName
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: {
      subnetResourceId: snetapi.id
    }
  }
  dependsOn: [
    snetapi
  ]
}

resource apim_gateway 'Microsoft.ApiManagement/service/gateways@2020-12-01' = {
  parent: apim
  name: 'my-gateway'
  properties: {
    locationData: {
      name: 'My internal location'
    }
    description: 'Self hosted gateway bringing API Management to the edge'
  }
}

resource apim_AppInsightsLogger 'Microsoft.ApiManagement/service/loggers@2020-12-01' = {
  parent: apim
  name: 'AppInsightsLogger'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: app_insights.id
    credentials: {
      instrumentationKey: app_insights.properties.InstrumentationKey
    }
  }
}

resource apim_AppInsights 'Microsoft.ApiManagement/service/diagnostics@2020-12-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: apim_AppInsightsLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        body: {
          bytes: 0
        }
      }
      response: {
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        body: {
          bytes: 0
        }
      }
      response: {
        body: {
          bytes: 0
        }
      }
    }
  }
}

resource Microsoft_Insights_diagnosticSettings_logToAnalytics 'Microsoft.Insights/diagnosticSettings@2017-05-01-preview' = {
  scope: apim
  name: 'logToAnalytics'
  properties: {
    workspaceId: log_analytics_workspace_id
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// OpenAI Account + Model
module openAi 'modules/cognitiveservices.bicep' = {
  name: 'my-openai-account'
  scope: resourceGroup()
  params: {
    name: 'openai'
    openaiLocation: openAiLocation
    sku: {
      name: 'S0'
    }
    customSubDomainName: customSubDomainName
    deployments: openai_model_deployments
  }
}

output publicEndpointFqdn string = publicIPAddress.properties.dnsSettings.fqdn
