# Flask API wrapper for the existing COBOL ACA Job

This add-on exposes a thin HTTP API that starts and inspects the existing Azure Container Apps Job without changing the COBOL image or Job definition.

## Shape

```text
Client
  -> Flask Container App: pb-job-api
  -> Azure Resource Manager start/list/read
  -> Existing COBOL ACA Job: pb-batch
```

The wrapper does not `exec` into the COBOL container and does not update the existing Job. It only calls Azure Resource Manager using its managed identity.

## API

```http
GET /
GET /docs
GET /openapi.json
GET /healthz
POST /jobs/pb-batch/runs
GET /jobs/pb-batch/runs
GET /jobs/pb-batch/runs/{executionName}
```

OpenAPI is available at `/openapi.json`. Swagger UI is available at `/docs`.

`POST /jobs/pb-batch/runs` returns `202 Accepted` after Azure accepts the Job start request. Use the `GET` endpoints to inspect executions. Console output remains in Log Analytics as documented in [docs/observability/log-analytics-queries.md](observability/log-analytics-queries.md).

## Build the API image

```bash
RESOURCE_GROUP=rg-practicebank
ACR_NAME=$(az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
IMAGE_TAG=$(git rev-parse --short HEAD)

az acr build \
  --registry "$ACR_NAME" \
  --image "practice-bank-api:$IMAGE_TAG" \
  --image "practice-bank-api:latest" \
  --file app/flask-job-api/Dockerfile \
  app/flask-job-api
```

## Deploy as a new Container App

This deploys only the Flask API. The existing COBOL Job `pb-batch` is referenced, not modified.

The principal running this deployment must be able to create role assignments on the existing ACR and the existing Job. In practice, use an account with `Owner` or `User Access Administrator` on those scopes. Without that, the API app can be created only as a shell and will not be able to pull the private image or start the Job.

```bash
RESOURCE_GROUP=rg-practicebank
ACA_ENV=cae-practicebank
API_APP=pb-job-api
TARGET_JOB=pb-batch
ACR_NAME=$(az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
IMAGE="$ACR_NAME.azurecr.io/practice-bank-api:latest"

az deployment group create \
  -g "$RESOURCE_GROUP" \
  -f infra/api-wrapper.bicep \
  -p apiAppName="$API_APP" \
     acaEnvName="$ACA_ENV" \
     acrName="$ACR_NAME" \
     image="$IMAGE" \
  targetJobName="$TARGET_JOB"
```

Set `externalIngress=true` only when the API is protected by Container Apps auth, API Management, or another access-control layer.

## Smoke test

With internal ingress, run the smoke test from a network that can reach the Container Apps environment. If you temporarily set `externalIngress=true` for a demo, the same commands work from your local shell.

```bash
FQDN=$(az containerapp show -g rg-practicebank -n pb-job-api --query properties.configuration.ingress.fqdn -o tsv)

curl -s "https://$FQDN/healthz" | jq
curl -s "https://$FQDN/openapi.json" | jq '.info.title, (.paths | keys)'
curl -s -X POST "https://$FQDN/jobs/pb-batch/runs" | jq
curl -s "https://$FQDN/jobs/pb-batch/runs" | jq
```

Open the Swagger UI in a browser:

```bash
"$BROWSER" "https://$FQDN/docs"
```

If `/healthz` works but Job endpoints return `AuthorizationFailed`, grant the API app access to the existing Job from an account with `Owner` or `User Access Administrator`:

```bash
RESOURCE_GROUP=rg-practicebank
API_APP=pb-job-api
TARGET_JOB=pb-batch

API_PRINCIPAL_ID=$(az containerapp show -g "$RESOURCE_GROUP" -n "$API_APP" --query identity.principalId -o tsv)
JOB_ID=$(az containerapp job show -g "$RESOURCE_GROUP" -n "$TARGET_JOB" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$API_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope "$JOB_ID"
```

After RBAC propagation, rerun:

```bash
curl -s "https://$FQDN/jobs/pb-batch/runs" | jq
curl -s -X POST "https://$FQDN/jobs/pb-batch/runs" | jq
```

## Access control

The Bicep template enables a system-assigned managed identity for the API Container App and grants:

- `AcrPull` on the existing ACR so the API app can pull its image.
- `Contributor` scoped to the existing `pb-batch` Job so the API can start and read executions.

For production, put this API behind Azure Container Apps auth, API Management, or private ingress. Keep `AZURE_CONTAINERAPP_ALLOWED_JOBS` restricted to the Jobs that should be exposed.

## Stop or remove

The API app is configured with `minReplicas=0`, so idle cost is minimized. To remove the wrapper entirely:

```bash
az containerapp delete -g rg-practicebank -n pb-job-api --yes
```

This does not delete or modify the existing COBOL Job `pb-batch`.