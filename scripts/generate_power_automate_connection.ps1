# ========= EDIT THESE =========
$TenantId       = "<your-tenant-id>"                  # Entra ID tenant GUID
$ClientId       = "<your-client-id>"                  # App registration (no secret needed; device code auth)
$OrgUrl         = "https://<yourorg>.crm.dynamics.com" # Dataverse environment URL
$FlowName       = "HTTP_to_PAD_Demo"

# Desktop flow (PAD) settings
$UiFlowId       = "<your-pad-uiFlowId-guid>"          # e.g. 418810c2-3b71-4013-acb6-be09e0b322da
$RunMode        = "attended"                          # or "unattended" (requires Unattended RPA license)
$MachineId      = "<your-machine-id-guid>"            # use this OR MachineGroupId
$MachineGroupId = ""                                  # leave empty if using MachineId

# HTTP trigger schema (adjust as needed)
$HttpSchema = @{
  type = "object"
  properties = @{
    a = @{ type = "string" }
    b = @{ type = "string" }
  }
  required = @("a")
}

# Connection reference name for Desktop Flows
$ConnectionRefName = "shared_uiflow"
# ==============================

# Get Dataverse token via Device Code
$Scope = "$OrgUrl/.default"
Write-Host "Signing in (device code) to $OrgUrl ..."
$dc = Invoke-RestMethod -Method POST `
  -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
  -Body @{ client_id = $ClientId; scope = $Scope } `
  -ContentType "application/x-www-form-urlencoded"

Write-Host $dc.message
$deviceCode = $dc.device_code
$Token = $null
while (-not $Token) {
  Start-Sleep -Seconds $dc.interval
  try {
    $Token = Invoke-RestMethod -Method POST `
      -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
      -Body @{
        grant_type = "urn:ietf:params:oauth:grant-type:device_code"
        client_id  = $ClientId
        device_code= $deviceCode
      } -ContentType "application/x-www-form-urlencoded"
  } catch {}
}
$AuthHeader = @{ Authorization = "Bearer $($Token.access_token)" }

# Build flow definition
$definition = @{
  '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
  contentVersion = '1.0.0.0'
  parameters = @{
    '$connections'    = @{ defaultValue = @{}; type = 'Object' }
    '$authentication' = @{ defaultValue = @{}; type = 'SecureObject' }
  }
  triggers = @{
    manual = @{
      type = 'Request'
      kind = 'Http'
      inputs = @{ schema = $HttpSchema }
    }
  }
  actions = @{
    Run_desktop_flow = @{
      runAfter = @{}
      type = 'OpenApiConnection'
      inputs = @{
        host = @{
          apiId          = '/providers/Microsoft.PowerApps/apis/shared_uiflow'
          connectionName = $ConnectionRefName
          operationId    = 'RunUIFlow_V2'
        }
        parameters = (@{
          uiFlowId = $UiFlowId
          runMode  = $RunMode
        } + ( if([string]::IsNullOrEmpty($MachineGroupId)){
                @{ machineId = $MachineId }
              } else {
                @{ machineGroupId = $MachineGroupId }
              }
            ) + @{
              inputParameters = @(
                @{ name = 'a_input'; type = 'Text'; value = "@{triggerBody()?['a']}" }
                @{ name = 'b_input'; type = 'Text'; value = "@{coalesce(triggerBody()?['b'],'')}" }
              )
        })
        authentication = "@parameters('$authentication')"
      }
    }
  }
}

$connectionReferences = @{
  $ConnectionRefName = @{
    runtimeSource = 'embedded'
    connection    = @{}     # bind to an existing connection instance in this environment
    api           = @{ name = $ConnectionRefName }
  }
}

$clientdata = @{
  properties = @{
    connectionReferences = $connectionReferences
    definition           = $definition
  }
  schemaVersion = '1.0.0.0'
} | ConvertTo-Json -Depth 20

# Create the Cloud Flow (Dataverse workflow record)
$createBody = @{
  name       = $FlowName
  category   = 5                     # modern cloud flow
  statecode  = 0                     # draft/off
  clientdata = $clientdata
} | ConvertTo-Json -Depth 20

$createUrl  = "$OrgUrl/api/data/v9.2/workflows"
$r = Invoke-WebRequest -Method POST -Uri $createUrl `
     -Headers ($AuthHeader + @{ "OData-Version"="4.0"; "Content-Type"="application/json" }) `
     -Body $createBody

$entityId = $r.Headers["OData-EntityId"]
if ($entityId -match "\((?<id>[0-9a-f-]{36})\)") { $workflowId = $Matches['id'] } else { throw "Cannot parse workflow id." }
Write-Host "Created Cloud Flow record: $workflowId"

# Turn it ON
$patchUrl  = "$OrgUrl/api/data/v9.2/workflows($workflowId)"
$patchBody = @{ statecode = 1 } | ConvertTo-Json
Invoke-RestMethod -Method PATCH -Uri $patchUrl `
  -Headers ($AuthHeader + @{ "OData-Version"="4.0"; "Content-Type"="application/json"; "If-Match"="*" }) `
  -Body $patchBody
Write-Host "Flow is ON. Done."
