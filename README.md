# multica-helm

Unofficial Helm chart for [Multica](https://github.com/multica-ai/multica) — a Kanban-style coordinator for AI coding agents.

The chart deploys:

- **backend** — Go API + WebSocket hub (`ghcr.io/multica-ai/multica-backend`)
- **frontend** — Next.js UI (`ghcr.io/multica-ai/multica-web`)
- **runners** (optional, any number) — long-lived daemons that poll the backend and spawn agent CLIs (Claude, Codex, Pi, …) as subprocesses

## Quick start

The chart is published as an OCI artifact at `ghcr.io/sshine/charts/multica`.

```bash
helm install multica oci://ghcr.io/sshine/charts/multica \
  --version 0.1.0 \
  --namespace multica --create-namespace \
  --set config.databaseUrl='postgres://multica:multica@postgres:5432/multica?sslmode=disable' \
  --set config.jwtSecret="$(openssl rand -base64 32)"
```

That brings up backend + frontend with no ingress and an emptyDir-style PVC for uploads. Browse to the frontend Service or `kubectl port-forward svc/multica-frontend 3000:3000`.

## Configuration

All knobs live in [`charts/multica/values.yaml`](charts/multica/values.yaml). The most common ones:

| Key | Default | Purpose |
|---|---|---|
| `config.databaseUrl` | `""` | Postgres DSN (required) |
| `config.jwtSecret` | `change-me-in-production` | JWT signing secret |
| `config.appEnv` | `production` | `development` enables the `888888` master login code — **never** use on public instances |
| `config.allowSignup` | `"true"` | Set to `"false"` to disable new signups |
| `config.allowedEmails` | `""` | Restrict signups to specific emails (comma-separated) |
| `secret.create` | `true` | Set to `false` and use `secret.existingSecret` if you manage the Secret yourself |
| `persistence.size` | `10Gi` | PVC for backend file uploads (skip if using S3) |
| `ingress.enabled` | `false` | Plain Ingress |
| `httpRoute.enabled` | `false` | Gateway API HTTPRoute |

### Example: with Ingress

```yaml
# values.yaml
config:
  databaseUrl: postgres://multica:multica@postgres:5432/multica?sslmode=disable
  jwtSecret: <generated>
  frontendOrigin: https://multica.example.com
  appUrl: https://multica.example.com

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: multica.example.com
      paths:
        - path: /
          pathType: Prefix
          service: frontend
  tls:
    - secretName: multica-tls
      hosts: [multica.example.com]
```

### Example: with Gateway API HTTPRoute

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: main
      namespace: istio-system
      sectionName: https
  hostnames: [multica.example.com]
```

### Example: bring your own Secret

If you'd rather create the Secret yourself (sealed-secrets, sops, External Secrets, Vault Secrets Operator, …):

```bash
kubectl create secret generic multica-config -n multica \
  --from-literal=DATABASE_URL='postgres://...' \
  --from-literal=JWT_SECRET="$(openssl rand -base64 32)"
```

```yaml
secret:
  create: false
  existingSecret: multica-config
```

The expected key names live under `secret.keys` in `values.yaml`.

## Runners

A **runner** is a long-lived daemon that authenticates as a Multica user and executes tasks the user assigns from the UI. Each runner is its own StatefulSet — declare as many as you like under `runners.<name>`.

You'll need:

1. **A daemon auth token** — log into the Multica UI as the user the runner should impersonate, then issue a daemon token. Store it in a Kubernetes Secret.
2. **An image with the agent CLI(s) installed** — the upstream `multica-backend` image has the daemon but no agent binaries. Either bake your own image with `claude`, `codex`, `pi`, … installed, or use `initContainers` to drop them onto the pod.

### Example: a Pi runner using Z.AI's GLM 5.1

This is a complete worked example. The runner uses [Pi](https://github.com/picohq/pi) as the agent CLI, talking to Z.AI's OpenAI-compatible endpoint.

#### Step 1 — build a runner image

The upstream `multica-backend` image ships the `multica` daemon but no agent CLIs. Layer the agent on top:

```dockerfile
# Dockerfile — illustrative; adapt the install step to whatever package
# source the agent ships from.
FROM ghcr.io/multica-ai/multica-backend:v0.2.15

USER root

# Install Node.js + the pi CLI. Replace this line for other agents
# (claude-code, codex, …) — the rest of the image stays the same.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm ca-certificates git \
 && npm install -g @picohq/pi \
 && rm -rf /var/lib/apt/lists/*

# Image-intrinsic env (paths that won't change per-deployment). Per-runner
# values like API keys and model selection stay in the chart's values.env.
ENV MULTICA_PI_PATH=/usr/bin/pi \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

USER 1000:1000
```

```bash
docker build -t ghcr.io/your-org/multica-runner-pi:0.1.0 .
docker push ghcr.io/your-org/multica-runner-pi:0.1.0
```

> If you'd rather build the image with Nix, see [`sshine/multica-runner`](https://git.shine.town/sshine/multica-runner/src/branch/main/nix/multica-runner.nix) for a working layered-image definition that pins the upstream digest and adds the pi CLI plus the usual dev tooling (git, git-lfs, ssh, curl, …).

#### Step 2 — create the Secrets (plain Kubernetes)

```bash
# The daemon auth token from the Multica UI:
kubectl create secret generic multica-runner -n multica \
  --from-literal=token='<paste-token-here>'

# The Z.AI API key (consumed by the pi CLI as $ZAI_API_KEY):
kubectl create secret generic zai-api-token -n multica \
  --from-literal=api_token='<your-zai-key>'
```

#### Step 3 — values

```yaml
# values.yaml
runners:
  pi:
    image:
      repository: ghcr.io/your-org/multica-runner-pi
      tag: latest

    # The runner authenticates by reading a token from this Secret and
    # writing it into ~/.multica/config.json (handled by the init container).
    auth:
      existingSecret: multica-runner
      key: token

    deviceName: k8s-pi-runner
    persistence:
      size: 20Gi

    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { memory: 2Gi }

    # Files dropped into the runner's $HOME before the daemon starts.
    # The pi agent reads ~/.pi/agent/models.json to discover providers.
    configFiles:
      - path: .pi/agent/models.json
        content: |
          {
            "providers": {
              "zai": {
                "baseUrl": "https://api.z.ai/api/coding/paas/v4",
                "apiKey": "ZAI_API_KEY",
                "api": "openai-completions",
                "compat": {
                  "supportsDeveloperRole": false,
                  "thinkingFormat": "zai",
                  "zaiToolStream": true
                },
                "models": [
                  {
                    "id": "glm-5.1",
                    "name": "Z.AI GLM 5.1",
                    "reasoning": true,
                    "input": ["text"],
                    "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
                    "contextWindow": 131072,
                    "maxTokens": 16384
                  }
                ]
              }
            }
          }

    # Per-runner env. Mix plain values and secret references freely — this
    # is the standard PodSpec env shape. Image-intrinsic vars (paths, CA
    # bundle) are baked into the Dockerfile above and don't repeat here.
    env:
      - name: ZAI_API_KEY
        valueFrom:
          secretKeyRef:
            name: zai-api-token
            key: api_token
      - name: MULTICA_PI_MODEL
        value: zai/glm-5.1
```

```bash
helm upgrade --install multica oci://ghcr.io/sshine/charts/multica \
  --version 0.1.0 -n multica -f values.yaml
```

#### Alternative: secrets via Vault Secrets Operator

If you have [Vault Secrets Operator](https://github.com/hashicorp/vault-secrets-operator) installed, replace the `kubectl create secret` calls with `VaultStaticSecret` CRDs that sync from Vault into the same Kubernetes Secret names. The chart values don't change — it still reads from `multica-runner` / `zai-api-token`.

```yaml
# Apply alongside the chart (not part of it).
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: multica-runner
  namespace: multica
spec:
  vaultAuthRef: vault/default
  mount: secret
  path: multica/runner       # KV-v2 path: secret/data/multica/runner
  type: kv-v2
  refreshAfter: 30s
  destination:
    name: multica-runner     # ← Secret name the chart references
    create: true
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: zai-api-token
  namespace: multica
spec:
  vaultAuthRef: vault/default
  mount: secret
  path: zai/api-token
  type: kv-v2
  refreshAfter: 30s
  destination:
    name: zai-api-token
    create: true
```

The pattern is general: **anything you'd reference via `secretKeyRef` or `existingSecret` in the chart can be backed by Vault via VSO without touching the chart values.**

### Runner reference

| Key | Purpose |
|---|---|
| `image.repository`/`tag` | Runner image (must contain the agent CLIs you intend to run) |
| `auth.existingSecret`/`key` | Secret holding the Multica daemon token |
| `deviceName` | Human-readable name shown in the Multica UI |
| `serverUrl` | Override backend WebSocket URL (default: cluster-internal) |
| `workspaceId` | Pin to a single workspace (default: auto-discover) |
| `pollInterval` / `heartbeatInterval` / `agentTimeout` | Daemon timing knobs |
| `maxConcurrentTasks` | Default `20` |
| `configFiles[]` | `{path, content, mode?}` files to drop into `$HOME` (e.g. agent config) |
| `env[]` | Standard PodSpec env list — supports `valueFrom.secretKeyRef` etc. |
| `initContainers[]` | Extra init containers, e.g. to install agent binaries at boot |
| `extraVolumes[]` / `extraVolumeMounts[]` | Mount additional secrets, ConfigMaps, … |
| `persistence.size` / `storageClass` | Workspaces volume |
| `resources` / `nodeSelector` / `tolerations` / `affinity` | Standard scheduling knobs |

## Development

Render and lint the chart locally:

```bash
helm lint charts/multica
helm template multica charts/multica -f my-values.yaml
```

Install from a working tree:

```bash
helm upgrade --install multica ./charts/multica -n multica --create-namespace -f my-values.yaml
```

## Releasing

Push a `v*.*.*` tag matching `Chart.yaml`'s `version`. The release workflow packages the chart, pushes it to `ghcr.io/<owner>/charts/multica:<version>`, and creates a GitHub Release with the `.tgz` attached.

```bash
git tag v0.1.1
git push origin v0.1.1
```
