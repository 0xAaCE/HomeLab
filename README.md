# HomeLab

GitOps-based homelab infrastructure using k3s and Argo CD for fully reproducible configuration management.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Remote Access via Cloudflare WARP](#6-set-up-remote-access-via-cloudflare-warp)
- [Repository Structure](#repository-structure)
- [Components](#components)
- [Secrets Management](#secrets-management)
- [Adding New Applications](#adding-new-applications)
- [Backup and Disaster Recovery](#backup-and-disaster-recovery)
- [Operational Tasks](#operational-tasks)
- [Troubleshooting](#troubleshooting)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Cloudflare Tunnel                     │
│        (Secure external access without port forwarding) │
│                                                         │
│  Public hostnames ──→ Services (ArgoCD, Infisical, etc) │
│  WARP (private)   ──→ SSH, internal services by LAN IP  │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────┴──────────────────────────────────┐
│                    k3s Cluster                           │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Argo CD (GitOps Controller)                       │ │
│  │  - Monitors Git repository                         │ │
│  │  - Auto-syncs cluster state                        │ │
│  │  - App-of-apps pattern                             │ │
│  └────────────────────────────────────────────────────┘ │
│                                                           │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Infisical (Secrets Manager)                       │ │
│  │  - PostgreSQL (persistent secret storage)          │ │
│  │  - Redis (caching layer)                           │ │
│  │  - Web UI for secret management                    │ │
│  └────────────────────────────────────────────────────┘ │
│                                                           │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Infisical Kubernetes Operator                     │ │
│  │  - Syncs secrets from Infisical → K8s Secrets      │ │
│  │  - Auto-updates on secret changes                  │ │
│  │  - Machine Identity authentication                 │ │
│  └────────────────────────────────────────────────────┘ │
│                                                           │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Your Applications                                 │ │
│  │  - Use secrets synced by operator                  │ │
│  │  - Managed via GitOps                              │ │
│  └────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
```

## Prerequisites

**Hardware/VM Requirements:**
- 2+ CPU cores
- 4GB+ RAM (8GB recommended for Infisical + apps)
- 40GB+ disk space (includes database storage)
- Ubuntu 20.04+ or similar Linux distribution

**Software:**
- `curl` installed
- `git` installed
- SSH key configured for GitHub (for private repos)

**External Services:**
- GitHub account for GitOps repository
- Cloudflare account (if using cloudflared tunnel)

## Quick Start

### 1. Fresh Installation

```bash
# Clone repository
git clone git@github.com:0xAaCE/HomeLab.git
cd HomeLab

# Install k3s + Argo CD
./scripts/setup.sh

# Set up kubectl access
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
chmod 600 ~/.kube/config
```

### 2. Configure Argo CD

```bash
# Set up SSH access to GitHub (required for private repos)
kubectl create secret generic homelab-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:0xAaCE/HomeLab.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository

# Apply Argo CD configuration (enables insecure mode for reverse proxy)
kubectl apply -f argocd/config/argocd-cmd-params-cm.yaml
kubectl rollout restart deployment argocd-server -n argocd
```

### 3. Bootstrap GitOps

```bash
# Apply app-of-apps pattern
kubectl apply -f argocd/app-of-apps.yaml

# Verify applications are syncing
kubectl get applications -n argocd
```

### 4. Set Up Secrets Management

#### Create Cloudflare Tunnel Token

1. Go to Cloudflare Zero Trust Dashboard → Networks → Tunnels
2. Create a new tunnel or use existing
3. Copy the tunnel token
4. Create Kubernetes secret:

```bash
kubectl create namespace cloudflared
kubectl create secret generic cloudflared-token \
  -n cloudflared \
  --from-literal=token='YOUR_TUNNEL_TOKEN_HERE'
```

5. Configure tunnel routes in Cloudflare Dashboard:
   - `argo.yourdomain.com` → `http://argocd-server.argocd.svc.cluster.local:80`
   - `secrets.yourdomain.com` → `http://infisical-infisical-standalone-infisical.infisical.svc.cluster.local:8080`

#### Set Up Infisical

Wait for Infisical to deploy (check with `kubectl get pods -n infisical`), then:

1. Access Infisical at `https://secrets.yourdomain.com`
2. Create your admin account
3. Create a project for your secrets

#### Configure Infisical Operator Authentication

1. In Infisical UI, navigate to: **Project Settings** → **Access Control** → **Machine Identities**
2. Click **Create Identity**:
   - Name: `kubernetes-operator`
   - Choose appropriate organization role
3. Add **Universal Auth** method:
   - Access Token TTL: `2592000` (30 days)
   - Access Token Max TTL: `2592000`
   - Trusted IPs: `0.0.0.0/0` (or restrict to cluster IPs)
   - **Save the Client ID and Client Secret**
4. Grant **Project Access**:
   - Select your project
   - Choose environments (dev, staging, prod)
   - Set role: Viewer or higher

5. Create Kubernetes secret with Machine Identity credentials:

```bash
kubectl create secret generic infisical-universal-auth \
  -n default \
  --from-literal=clientId='YOUR_CLIENT_ID' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET'
```

#### Create Database Credentials

```bash
# Generate secure passwords
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 16)
AUTH_SECRET=$(openssl rand -base64 32)

# Create database secrets
kubectl create secret generic db-credentials -n infisical \
  --from-literal=password="$DB_PASSWORD"

kubectl create secret generic redis-credentials -n infisical \
  --from-literal=password="$REDIS_PASSWORD"

# Create Infisical secrets
kubectl create secret generic infisical-secrets -n infisical \
  --from-literal=ENCRYPTION_KEY="$ENCRYPTION_KEY" \
  --from-literal=AUTH_SECRET="$AUTH_SECRET" \
  --from-literal=SITE_URL='https://secrets.yourdomain.com' \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:${DB_PASSWORD}@postgres:5432/infisical" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379"

# IMPORTANT: Save these credentials securely!
echo "Database Password: $DB_PASSWORD" > ~/infisical-credentials.txt
echo "Redis Password: $REDIS_PASSWORD" >> ~/infisical-credentials.txt
echo "Encryption Key: $ENCRYPTION_KEY" >> ~/infisical-credentials.txt
echo "Auth Secret: $AUTH_SECRET" >> ~/infisical-credentials.txt
chmod 600 ~/infisical-credentials.txt
```

### 5. Access Argo CD UI

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Access via Cloudflare Tunnel at https://argo.yourdomain.com
# Username: admin
# Password: (from command above)
```

### 6. Set Up Remote Access via Cloudflare WARP

Cloudflare WARP allows you to SSH into the homelab (and access internal services) from anywhere, without exposing ports or creating public hostnames for every service.

**How it works:**

```
Your device (WARP client) → Cloudflare edge → cloudflared pod in k3s → homelab LAN
```

All configuration is done in the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com) — no k8s manifest changes needed.

#### Step 1: Add a Private Network Route

1. Go to **Networks → Routes → CIDR**
2. Click **Add CIDR route**
3. Enter your homelab's LAN IP (e.g. `192.168.1.50/32` for a single host, or `192.168.1.0/24` for the whole subnet)
4. Select your cloudflared tunnel
5. Save

#### Step 2: Configure Split Tunnels

By default, WARP excludes private IP ranges (like `192.168.0.0/16`) from the tunnel. You must remove this exclusion so traffic reaches your homelab.

1. Go to **Settings → Devices → Device profiles**
2. Click your profile (e.g. "Default") → **Configure**
3. Scroll to **Split Tunnels** → click **Manage**
4. Find `192.168.0.0/16` and **delete it**

> **Note:** If your local network also uses `192.168.x.x`, you may lose local network access while WARP is connected. To avoid this, remove the `/16` and add back your specific local subnet (e.g. `192.168.1.0/24`) as an exclusion, while keeping your homelab IP routable.

#### Step 3: Create a Device Enrollment Policy

1. Go to **Settings → WARP Client → Device enrollment permissions → Manage**
2. Add a rule:
   - **Rule name:** `Allow my Google account`
   - **Rule action:** Allow
   - **Include:** Emails → your Google email address

#### Step 4: Install and Enroll the WARP Client

1. Download Cloudflare WARP from [https://one.one.one.one](https://one.one.one.one)
2. Open WARP → Settings → Account → **Login to Cloudflare Zero Trust**
3. Enter your team name (from `<team-name>.cloudflareaccess.com`)
4. Authenticate with Google
5. WARP should switch from "1.1.1.1" mode to **Zero Trust** mode

#### Verify

```bash
# With WARP connected, SSH into the homelab
ssh user@<homelab-lan-ip>

# Disconnect WARP and confirm it's no longer reachable
```

#### Troubleshooting WARP

```bash
# Check if traffic is reaching the tunnel (run on a machine with kubectl access)
kubectl logs -n cloudflared <pod-name> -f
# Then try SSH from your WARP device — you should see log entries

# The cloudflared container is minimal (no ping, wget, etc.)
# Use kubectl logs as the primary debugging tool
```

## Repository Structure

```
HomeLab/
├── scripts/
│   └── setup.sh                       # k3s + Argo CD installation
├── argocd/
│   ├── app-of-apps.yaml               # Root application (GitOps bootstrap)
│   ├── config/
│   │   └── argocd-cmd-params-cm.yaml  # Argo CD server configuration
│   └── README.md                      # Argo CD setup guide
├── apps/
│   ├── cloudflared.yaml               # Cloudflare Tunnel application
│   ├── cloudflared/                   # Tunnel manifests
│   ├── infisical-helm.yaml            # Infisical application
│   ├── infisical-db.yaml              # Database application
│   ├── infisical-db/                  # PostgreSQL & Redis manifests
│   ├── infisical-operator.yaml        # Operator application
│   ├── infisical-operator-config.yaml # Operator config application
│   ├── infisical-operator/            # Operator configuration
│   └── <your-app>.yaml                # Your application definitions
├── README.md                          # This file
└── SECRETS.md                         # Secrets management guide
```

## Components

| Component | Version | Purpose | Status |
|-----------|---------|---------|--------|
| **k3s** | Latest | Lightweight Kubernetes distribution | ✅ Running |
| **Argo CD** | v3.3.0 | GitOps continuous delivery tool | ✅ Running |
| **Cloudflared** | 2024.12.2 | Secure tunnel for external access | ✅ Running |
| **Infisical** | 1.7.2 | Self-hosted secrets management platform | ✅ Running |
| **PostgreSQL** | 16-alpine | Database for Infisical | ✅ Running |
| **Redis** | 7.2-alpine | Caching layer for Infisical | ✅ Running |
| **Infisical Operator** | 0.10.19 | Syncs secrets to Kubernetes | ✅ Running |

### Component Details

#### k3s
- Minimal resource usage, perfect for homelab
- Built-in load balancer (servicelb)
- Automatic snapshots for backup

#### Argo CD
- Declarative GitOps
- Automatic sync from Git
- App-of-apps pattern for managing all applications
- Easy rollbacks

#### Cloudflare Tunnel
- Zero-trust access without port forwarding
- No public IP exposure
- Automatic TLS certificates
- DDoS protection
- **WARP integration** for private network access (SSH, internal services) from enrolled devices

#### Infisical
- Self-hosted secrets management
- Web UI for managing secrets
- Project and environment isolation
- API access for automation
- Kubernetes operator integration

#### Infisical Kubernetes Operator
- Automatically syncs secrets from Infisical to Kubernetes Secrets
- Supports dynamic secrets and push/pull operations
- Machine Identity authentication
- Auto-rotation capabilities

## Secrets Management

This homelab uses **Infisical** as the centralized secrets management platform.

### Architecture

```
┌─────────────────────────────────────────────┐
│  Infisical (Source of Truth)               │
│  - Store secrets in projects/environments  │
│  - Manage via Web UI                       │
└──────────────────┬──────────────────────────┘
                   │
                   │ Machine Identity Auth
                   │
┌──────────────────▼──────────────────────────┐
│  Infisical Kubernetes Operator              │
│  - Watches InfisicalSecret CRDs             │
│  - Syncs to Kubernetes Secrets              │
└──────────────────┬──────────────────────────┘
                   │
                   │ Creates/Updates
                   │
┌──────────────────▼──────────────────────────┐
│  Kubernetes Secrets                         │
│  - Used by applications                     │
│  - Auto-updated on Infisical changes        │
└─────────────────────────────────────────────┘
```

### Using Infisical for Application Secrets

**Step 1: Add secrets to Infisical**

1. Go to Infisical Web UI (`https://secrets.yourdomain.com`)
2. Navigate to your project
3. Select environment (dev/staging/prod)
4. Add secrets with key-value pairs

**Step 2: Create InfisicalSecret CRD**

Create `apps/myapp/infisical-secret.yaml`:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: myapp-secrets
  namespace: myapp
spec:
  # Sync interval (check for updates)
  resyncInterval: 60

  authentication:
    universalAuth:
      secretsScope:
        projectSlug: your-project-slug  # From Infisical project URL
        envSlug: prod                   # Environment: dev, staging, prod
        secretsPath: "/"                # Path within environment
      credentialsRef:
        secretName: infisical-universal-auth
        secretNamespace: default

  managedSecretReference:
    secretName: myapp-secrets           # K8s Secret to create
    secretNamespace: myapp
    creationPolicy: "Orphan"            # Keep secret if CRD is deleted
```

**Step 3: Reference secrets in your application**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  template:
    spec:
      containers:
      - name: myapp
        image: myapp:v1.0.0
        env:
        # Option 1: Individual env vars
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: API_KEY

        # Option 2: All secrets as env vars
        envFrom:
        - secretRef:
            name: myapp-secrets

        # Option 3: Mount as files
        volumeMounts:
        - name: secrets
          mountPath: "/etc/secrets"
          readOnly: true

      volumes:
      - name: secrets
        secret:
          secretName: myapp-secrets
```

**Benefits:**
- ✅ Secrets stored centrally in Infisical
- ✅ Automatic sync to Kubernetes
- ✅ No manual kubectl commands needed
- ✅ Audit trail in Infisical
- ✅ Environment-specific secrets
- ✅ GitOps-friendly (CRDs in Git, not secrets)

See [SECRETS.md](./SECRETS.md) for detailed secrets management guide.

## Adding New Applications

### Method 1: Kustomize-based Application

**Step 1: Create application directory**

```bash
mkdir -p apps/myapp
```

**Step 2: Create manifests**

`apps/myapp/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

`apps/myapp/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: myapp
        image: myapp:v1.0.0  # ⚠️ Always pin versions
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
```

`apps/myapp/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
```

**Step 3: Create Argo CD Application**

`apps/myapp.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:0xAaCE/HomeLab.git
    targetRevision: main
    path: apps/myapp
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 4: Deploy**

```bash
git add apps/myapp apps/myapp.yaml
git commit -m "Add myapp application"
git push

# Argo CD auto-syncs within 3 minutes
```

### Method 2: Helm-based Application

`apps/myapp-helm.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: myapp
    targetRevision: 1.2.3  # Pin chart version
    helm:
      values: |
        replicaCount: 1
        image:
          repository: myapp
          tag: "v1.0.0"
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Backup and Disaster Recovery

### What Gets Backed Up Automatically

✅ **Applications** - All configs in Git
✅ **Argo CD state** - k3s etcd snapshots
✅ **Infisical secrets** - PostgreSQL database with persistent volumes

### Manual Backups

**1. K3s etcd (cluster state):**

```bash
# k3s auto-creates snapshots in /var/lib/rancher/k3s/server/db/snapshots/
sudo ls -lah /var/lib/rancher/k3s/server/db/snapshots/

# Manual snapshot
sudo k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d-%H%M%S)

# Copy to safe location
sudo cp /var/lib/rancher/k3s/server/db/snapshots/* ~/backups/
```

**2. Infisical Database (PostgreSQL):**

```bash
# Backup PostgreSQL database
kubectl exec -n infisical postgres-0 -- pg_dump -U infisical infisical > infisical-backup-$(date +%Y%m%d).sql

# Or backup the entire PVC
kubectl get pvc -n infisical
# Use volume snapshot tools or manual copy
```

**3. Critical Kubernetes Secrets:**

```bash
# Backup operator auth secret
kubectl get secret infisical-universal-auth -n default -o yaml > infisical-auth-backup.yaml

# Backup database credentials
kubectl get secret db-credentials redis-credentials -n infisical -o yaml > infisical-db-creds-backup.yaml

# Backup cloudflared token
kubectl get secret cloudflared-token -n cloudflared -o yaml > cloudflared-backup.yaml

# ⚠️ ENCRYPT these backups before storing!
gpg --symmetric --cipher-algo AES256 *-backup.yaml
```

### Full Cluster Restore

**Option 1: From Git (recommended for most cases)**

```bash
# 1. Fresh k3s install
./scripts/setup.sh
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config

# 2. Restore critical secrets
gpg --decrypt secrets-backup.yaml.gpg > secrets-backup.yaml
kubectl apply -f secrets-backup.yaml

# 3. Configure Argo CD
kubectl apply -f argocd/config/argocd-cmd-params-cm.yaml
kubectl rollout restart deployment argocd-server -n argocd

kubectl create secret generic homelab-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:0xAaCE/HomeLab.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository

# 4. Bootstrap GitOps (restores all apps)
kubectl apply -f argocd/app-of-apps.yaml

# 5. Restore Infisical database (if needed)
kubectl exec -n infisical postgres-0 -- psql -U infisical infisical < infisical-backup.sql
```

**Option 2: From etcd snapshot (for complete state restore)**

```bash
# Uninstall k3s
/usr/local/bin/k3s-uninstall.sh

# Reinstall with snapshot
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-reset \
  --cluster-reset-restore-path=/path/to/snapshot
```

## Operational Tasks

### Check Application Status

```bash
# List all applications
kubectl get applications -n argocd

# Detailed app status
kubectl describe application <app-name> -n argocd

# Check pods
kubectl get pods -n <namespace>
```

### Manual Sync

```bash
# Sync specific app
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'

# Via Argo CD UI: Click "Sync" button
```

### View Logs

```bash
# Application logs
kubectl logs -n <namespace> -l app=<app-name> --tail=100 -f

# Infisical logs
kubectl logs -n infisical -l app.kubernetes.io/name=infisical-standalone --tail=100 -f

# Operator logs
kubectl logs -n infisical-operator-system -l control-plane=controller-manager --tail=100 -f
```

### Update Application

```bash
# Edit manifests
vim apps/myapp/deployment.yaml

# Commit and push
git add apps/myapp/deployment.yaml
git commit -m "Update myapp configuration"
git push

# Argo CD auto-syncs within 3 minutes
```

### Verify Infisical Operator Sync

```bash
# Check InfisicalSecret status
kubectl get infisicalsecret -n <namespace>

# Detailed status
kubectl describe infisicalsecret <name> -n <namespace>

# Verify synced Kubernetes Secret
kubectl get secret <managed-secret-name> -n <namespace> -o yaml
```

## Troubleshooting

### Argo CD Issues

**ERR_TOO_MANY_REDIRECTS**

```bash
# Ensure insecure mode is enabled
kubectl apply -f argocd/config/argocd-cmd-params-cm.yaml
kubectl rollout restart deployment argocd-server -n argocd

# Verify Cloudflare Tunnel points to port 80:
# http://argocd-server.argocd.svc.cluster.local:80
```

**Repository SSH errors**

```bash
# Verify SSH secret
kubectl get secret homelab-repo -n argocd

# Recreate if needed
kubectl delete secret homelab-repo -n argocd
kubectl create secret generic homelab-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:0xAaCE/HomeLab.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519
kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository
```

### Infisical Issues

**Infisical pod not starting**

```bash
# Check pod status
kubectl get pods -n infisical

# View logs
kubectl logs -n infisical <infisical-pod-name>

# Check database connectivity
kubectl exec -n infisical postgres-0 -- psql -U infisical -d infisical -c "\dt"

# Verify secrets exist
kubectl get secrets -n infisical
```

**Cannot access Infisical UI**

1. Check pod is running: `kubectl get pods -n infisical`
2. Verify service: `kubectl get svc -n infisical`
3. Check Cloudflare Tunnel configuration
4. Test internal connectivity:
   ```bash
   kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never -- \
     curl -s http://infisical-infisical-standalone-infisical.infisical.svc.cluster.local:8080/api/status
   ```

### Infisical Operator Issues

**Secrets not syncing**

```bash
# Check operator is running
kubectl get pods -n infisical-operator-system

# Check InfisicalSecret status
kubectl describe infisicalsecret <name> -n <namespace>

# Verify authentication secret exists
kubectl get secret infisical-universal-auth -n default

# Check operator logs
kubectl logs -n infisical-operator-system -l control-plane=controller-manager --tail=100
```

**Authentication errors**

```bash
# Verify Machine Identity credentials in Infisical UI
# Re-create authentication secret with correct Client ID/Secret
kubectl delete secret infisical-universal-auth -n default
kubectl create secret generic infisical-universal-auth -n default \
  --from-literal=clientId='YOUR_CLIENT_ID' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET'
```

### Database Issues

**PostgreSQL connection failures**

```bash
# Check PostgreSQL pod
kubectl get pod postgres-0 -n infisical

# Test connection
kubectl exec -n infisical postgres-0 -- psql -U infisical -d infisical -c "SELECT 1"

# Check logs
kubectl logs -n infisical postgres-0
```

**Redis connection failures**

```bash
# Check Redis pod
kubectl get pods -n infisical -l app=redis

# Test connection
kubectl exec -n infisical <redis-pod-name> -- redis-cli ping
```

### General k3s Issues

**k3s not responding**

```bash
# Check k3s service
sudo systemctl status k3s

# Restart k3s
sudo systemctl restart k3s

# Check node status
kubectl get nodes

# View k3s logs
sudo journalctl -u k3s -n 100 -f
```

**Out of disk space**

```bash
# Check disk usage
df -h

# Clean up Docker images
sudo k3s crictl rmi --prune

# Clean up old etcd snapshots
sudo rm /var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-old-*
```

## Best Practices

1. **Always pin versions** - Avoid `:latest` tags
2. **Set resource limits** - Prevent resource exhaustion
3. **Use meaningful commit messages** - Helps with debugging
4. **Test locally first** - Before pushing to production
5. **Monitor disk usage** - Databases grow over time
6. **Backup regularly** - Automate backups with cron jobs
7. **Rotate secrets** - Update Infisical secrets periodically
8. **Document changes** - Update README for significant changes

## Contributing

When adding new applications:
1. Pin all image and chart versions
2. Include resource requests/limits
3. Add secrets via Infisical + operator
4. Document any special setup requirements
5. Test thoroughly before committing

## License

MIT License - See LICENSE file for details
