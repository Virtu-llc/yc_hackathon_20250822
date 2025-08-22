#!/usr/bin/env bash
set -euo pipefail

# ===================== EDIT THESE =====================
TENANT_ID="<your-tenant-id-guid>"
CLIENT_ID="<your-entra-app-client-id>"
ORG_URL="https://<yourorg>.crm.dynamics.com"     # Dataverse environment URL
FLOW_NAME="HTTP_to_PAD_Demo"

# Desktop flow (PAD) settings
UIFLOW_ID="<your-pad-uiFlowId-guid>"             # e.g. 418810c2-3b71-4013-acb6-be09e0b322da
RUN_MODE="attended"                               # or "unattended" (requires Unattended RPA license)
MACHINE_ID="<your-machine-id-guid>"               # Use either MACHINE_ID or MACHINE_GROUP_ID
MACHINE_GROUP_ID=""                               # Leave empty if using MACHINE_ID

# HTTP trigger schema (adjust to your needs)
# This example expects JSON body like: { "a": "...", "b": "..." }
HTTP_SCHEMA_JSON='{
  "type":"object",
  "properties": {
    "a":{"type":"string"},
    "b":{"type":"string"}
  },
  "required": ["a"]
}'

# Connection reference name for Desktop Flows connector
CONNECTION_REF_NAME="shared_uiflow"
# ======================================================

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
require curl
require jq

SCOPE="$ORG_URL/.default"

echo "==> Requesting device code (sign in) ..."
DC_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/devicecode" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "scope=$SCOPE")

echo "$DC_RESP" | jq -r '.message'
DEVICE_CODE=$(echo "$DC_RESP" | jq -r '.device_code')
INTERVAL=$(echo "$DC_RESP" | jq -r '.interval')

echo "==> Waiting for you to complete sign-in ..."
while :; do
  sleep "$INTERVAL"
  TOKEN_RESP=$(curl -sS -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "device_code=$DEVICE_CODE" ) || true

  ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r 'select(.access_token)!=null | .access_token' 2>/dev/null || true)
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    echo "==> Signed in."
    break
  fi
  ERR=$(echo "$TOKEN_RESP" | jq -r '.error // empty')
  [[ "$ERR" == "authorization_pending" ]] && continue
  [[ -n "$ERR" ]] && { echo "OAuth error: $ERR"; echo "$TOKEN_RESP" | jq -c .; exit 1; }
done

AUTHZ="Authorization: Bearer $ACCESS_TOKEN"
OD_VER="OData-Version: 4.0"
CT_JSON="Content-Type: application/json"

echo "==> Building Cloud Flow definition ..."
# Build the action 'RunUIFlow_V2' parameters block dynamically with jq
RUN_PARAMS=$(jq -n \
  --arg uiFlowId "$UIFLOW_ID" \
  --arg runMode "$RUN_MODE" \
  --arg machineId "$MACHINE_ID" \
  --arg machineGroupId "$MACHINE_GROUP_ID" \
  --argjson schema "$HTTP_SCHEMA_JSON" '
  {
    "uiFlowId": $uiFlowId,
    "runMode": $runMode
  }
  +
  ( if ($machineGroupId|length)>0 then {"machineGroupId":$machineGroupId} else {"machineId":$machineId} end )
  +
  {
    "inputParameters": [
      { "name":"a_input", "type":"Text", "value":"@{triggerBody()?['a']}" },
      { "name":"b_input", "type":"Text", "value":"@{coalesce(triggerBody()?['b'], '''')}" }
    ]
  }')

DEFINITION=$(jq -n \
  --argjson schema "$HTTP_SCHEMA_JSON" \
  --argjson params "$RUN_PARAMS" '
{
  "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "$connections":    { "defaultValue": {}, "type": "Object" },
    "$authentication": { "defaultValue": {}, "type": "SecureObject" }
  },
  "triggers": {
    "manual": {
      "type": "Request",
      "kind": "Http",
      "inputs": { "schema": $schema }
    }
  },
  "actions": {
    "Run_desktop_flow": {
      "runAfter": {},
      "type": "OpenApiConnection",
      "inputs": {
        "host": {
          "apiId": "/providers/Microsoft.PowerApps/apis/shared_uiflow",
          "connectionName": "'$CONNECTION_REF_NAME'",
          "operationId": "RunUIFlow_V2"
        },
        "parameters": $params,
        "authentication": "@parameters(''$authentication'')"
      }
    }
  }
}')

CONNECTION_REFS=$(jq -n --arg name "$CONNECTION_REF_NAME" '
{
  ($name): {
    "runtimeSource": "embedded",
    "connection": {},               # bind to an existing shared_uiflow connection in this environment
    "api": { "name": $name }
  }
}')

CLIENTDATA=$(jq -n --argjson def "$DEFINITION" --argjson refs "$CONNECTION_REFS" '
{
  "properties": {
    "connectionReferences": $refs,
    "definition": $def
  },
  "schemaVersion":"1.0.0.0"
}')

CREATE_BODY=$(jq -n --arg name "$FLOW_NAME" --argjson clientdata "$CLIENTDATA" '
{
  "name": $name,
  "category": 5,     # modern cloud flow
  "statecode": 0,    # draft/off
  "clientdata": $clientdata
}')

echo "==> Creating Cloud Flow ..."
CREATE_RESP_HEADERS=$(mktemp)
curl -sS -D "$CREATE_RESP_HEADERS" -o /dev/null \
  -X POST "$ORG_URL/api/data/v9.2/workflows" \
  -H "$AUTHZ" -H "$OD_VER" -H "$CT_JSON" \
  --data "$CREATE_BODY"

ENTITY_ID=$(grep -i "^OData-EntityId:" "$CREATE_RESP_HEADERS" | awk '{print $2}' | tr -d '\r\n')
rm -f "$CREATE_RESP_HEADERS"

if [[ -z "${ENTITY_ID:-}" ]]; then
  echo "Failed to create workflow. Response headers:"
  cat "$CREATE_RESP_HEADERS" || true
  exit 1
fi

# Extract GUID from OData-EntityId
WORKFLOW_ID=$(echo "$ENTITY_ID" | grep -oE '\(([0-9a-fA-F-]{36})\)' | tr -d '()')
echo "==> Created Cloud Flow: $WORKFLOW_ID"

echo "==> Turning the flow ON ..."
PATCH_BODY='{"statecode":1}'
curl -sS -X PATCH "$ORG_URL/api/data/v9.2/workflows($WORKFLOW_ID)" \
  -H "$AUTHZ" -H "$OD_VER" -H "$CT_JSON" -H "If-Match: *" \
  --data "$PATCH_BODY" >/dev/null

echo "✅ Done. Flow is ON."
echo
echo "Next steps:"
echo "1) Ensure you already have a valid **shared_uiflow** connection in this environment (bound to your machine/machine group)."
echo "2) Open the flow in Power Automate UI to copy the **HTTP POST URL** (the trigger’s callback URL)."
echo "3) Test with:"
echo "   curl -X POST \"<YOUR_FLOW_HTTP_TRIGGER_URL>\" -H 'Content-Type: application/json' -d '{\"a\":\"hello\",\"b\":\"world\"}'"
