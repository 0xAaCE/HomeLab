# HomeLab

GitOps-based homelab infrastructure using k3s and Argo CD for fully reproducible configuration management.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Repository Structure](#repository-structure)
- [Adding New Applications](#adding-new-applications)
- [Secrets Management](#secrets-management)
- [Backup and Disaster Recovery](#backup-and-disaster-recovery)
- [Operational Tasks](#operational-tasks)
- [Components](#components)

## Prerequisites

**Hardware/VM Requirements:**
- 2+ CPU cores
- 4GB+ RAM (8GB recommended)
- 20GB+ disk space
- Ubuntu 20.04+ or similar Linux distribution

**Software:**
- `curl` installed
- `kubectl` (installed by setup script)
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

### 4. Access Argo CD UI

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Port forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open browser to https://localhost:8080
# Username: admin
# Password: (from command above)
```

## Repository Structure

```
HomeLab/
├── scripts/
│   └── setup.sh              # k3s + Argo CD installation
├── argocd/
│   └── app-of-apps.yaml      # Root application (GitOps bootstrap)
├── apps/
│   ├── <app-name>.yaml       # Argo CD Application definition
│   └── <app-name>/           # Application manifests
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── *.yaml            # Kubernetes resources
└── README.md
```

## Adding New Applications

### Step 1: Create Application Directory

```bash
mkdir -p apps/myapp
```

### Step 2: Create Kubernetes Manifests

Create `apps/myapp/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

Create `apps/myapp/deployment.yaml`:
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

Create `apps/myapp/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
```

### Step 3: Create Argo CD Application

Create `apps/myapp.yaml`:
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
      prune: true      # Delete resources removed from git
      selfHeal: true   # Sync when cluster state drifts
    syncOptions:
      - CreateNamespace=true
```

### Step 4: Deploy

```bash
# Commit and push
git add apps/myapp apps/myapp.yaml
git commit -m "Add myapp application"
git push

# Argo CD will automatically sync within 3 minutes
# Or trigger manually:
argocd app sync apps
```

## Secrets Management

**⚠️ NEVER commit secrets to Git in plain text**

### Current Approach: Manual Secret Creation

For applications requiring secrets (like cloudflared):

```bash
# Create namespace first
kubectl create namespace cloudflared

# Create secret manually
kubectl create secret generic cloudflared-token \
  -n cloudflared \
  --from-literal=token='YOUR_TUNNEL_TOKEN_HERE'

# Verify secret exists
kubectl get secret cloudflared-token -n cloudflared
```

### Recommended: Use Sealed Secrets (Future Enhancement)

For production setups, consider:
- **Sealed Secrets**: Encrypt secrets that can be safely stored in Git
- **External Secrets Operator**: Sync from external secret stores (Vault, AWS Secrets Manager)
- **SOPS**: Encrypt YAML files with age or PGP

Example workflow with Sealed Secrets:
```bash
# Install sealed-secrets controller
kubectl apply -f apps/sealed-secrets.yaml

# Create sealed secret
echo -n 'YOUR_TOKEN' | kubectl create secret generic myapp-secret \
  --dry-run=client --from-file=token=/dev/stdin -o yaml | \
  kubeseal -o yaml > apps/myapp/sealed-secret.yaml

# Commit sealed secret (safe to commit)
git add apps/myapp/sealed-secret.yaml
git commit -m "Add encrypted secret"
```

## Backup and Disaster Recovery

### Manual Backup

**1. Backup k3s etcd (cluster state):**
```bash
# k3s automatically creates snapshots in /var/lib/rancher/k3s/server/db/snapshots/
sudo ls -lah /var/lib/rancher/k3s/server/db/snapshots/

# Manual snapshot
sudo k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d-%H%M%S)

# Copy to safe location
sudo cp /var/lib/rancher/k3s/server/db/snapshots/* ~/backups/
```

**2. Backup manually created secrets:**
```bash
# Export all secrets (⚠️ contains sensitive data)
kubectl get secrets --all-namespaces -o yaml > secrets-backup.yaml

# Store securely (encrypted external storage)
```

**3. GitOps handles the rest**
All application configurations are in Git, so your infrastructure is already backed up.

### Disaster Recovery

**Full cluster rebuild:**
```bash
# 1. Fresh install
./scripts/setup.sh

# 2. Restore manually created secrets
kubectl apply -f secrets-backup.yaml

# 3. Bootstrap GitOps (automatically restores all apps)
kubectl apply -f argocd/app-of-apps.yaml

# 4. Verify all applications sync
kubectl get applications -n argocd
argocd app sync apps
```

**Restore from etcd snapshot:**
```bash
# Uninstall k3s
/usr/local/bin/k3s-uninstall.sh

# Reinstall with snapshot restore
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-reset \
  --cluster-reset-restore-path=/path/to/snapshot
```

## Operational Tasks

### Check Application Status

```bash
# List all applications
kubectl get applications -n argocd

# Get detailed app info
argocd app get <app-name>

# View sync status
argocd app list
```

### Manual Sync

```bash
# Sync specific application
argocd app sync <app-name>

# Sync all applications
argocd app sync -l app.kubernetes.io/instance=apps
```

### View Logs

```bash
# Application logs
kubectl logs -n <namespace> -l app=<app-name> --tail=100 -f

# Argo CD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100 -f
```

### Update Application

```bash
# Edit manifests locally
vim apps/myapp/deployment.yaml

# Commit and push
git add apps/myapp/deployment.yaml
git commit -m "Update myapp configuration"
git push

# Argo CD syncs automatically (or manual sync)
argocd app sync myapp
```

### Rollback Application

```bash
# View history
argocd app history myapp

# Rollback to previous version
argocd app rollback myapp <history-id>
```

### Delete Application

```bash
# Remove from Git
git rm apps/myapp.yaml
git rm -r apps/myapp/
git commit -m "Remove myapp"
git push

# Argo CD will automatically prune resources
# Or delete manually:
argocd app delete myapp
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| **k3s** | Latest | Lightweight Kubernetes distribution |
| **Argo CD** | v3.3.0 | GitOps continuous delivery tool |
| **Cloudflared** | Latest* | Secure tunnel for external access |

*⚠️ Recommendation: Pin to specific version for reproducibility

### Why These Tools?

- **k3s**: Minimal resource usage, perfect for homelab environments
- **Argo CD**: Declarative GitOps, automatic sync, easy rollbacks
- **Cloudflared**: Zero-trust access without exposing ports/IP addresses

## Troubleshooting

### Argo CD ERR_TOO_MANY_REDIRECTS

If accessing Argo CD through Cloudflare Tunnel causes redirect loops:

```bash
# Ensure Argo CD is in insecure mode (required for reverse proxy)
kubectl apply -f argocd/config/argocd-cmd-params-cm.yaml
kubectl rollout restart deployment argocd-server -n argocd
```

**Important:** Update your Cloudflare Tunnel to use port **80**:
- Change: `http://argocd-server.argocd.svc.cluster.local:443` ❌
- To: `http://argocd-server.argocd.svc.cluster.local:80` ✅

The reverse proxy handles TLS, so Argo CD serves plain HTTP on port 80.

### Argo CD not syncing

```bash
# Check app status
kubectl get applications -n argocd
argocd app get <app-name>

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Force refresh
argocd app get <app-name> --refresh
```

### Repository SSH access errors

If apps show "ComparisonError" with SSH agent errors:

```bash
# Verify SSH secret exists
kubectl get secret homelab-repo -n argocd

# Recreate if needed (see Quick Start step 2)
kubectl create secret generic homelab-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:0xAaCE/HomeLab.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository
```

### Pod not starting

```bash
# Check pod status
kubectl get pods -n <namespace>

# Describe pod for events
kubectl describe pod <pod-name> -n <namespace>

# Check logs
kubectl logs <pod-name> -n <namespace>
```

### k3s not responding

```bash
# Check k3s service
sudo systemctl status k3s

# Restart k3s
sudo systemctl restart k3s

# Check node status
kubectl get nodes
```

## Contributing

When adding new applications:
1. Always pin image versions (avoid `:latest`)
2. Include resource limits
3. Test locally before pushing
4. Document any required manual secrets
5. Use meaningful commit messages

## License

MIT License - See LICENSE file for details
