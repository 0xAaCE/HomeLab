# Secrets Management Guide

This document explains how to manage secrets in your HomeLab GitOps setup.

## Current Approach: Manual Secrets

Currently, secrets are created manually using `kubectl`. This works but has limitations:
- Not stored in Git (manual recovery required)
- No version control for secrets
- Manual recreation needed after disaster recovery

## Creating Secrets for Applications

### Cloudflared Tunnel

**Step 1: Create Cloudflare Tunnel**
```bash
# Install cloudflared CLI
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/

# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create homelab

# Get tunnel credentials (save this)
cat ~/.cloudflared/*.json
```

**Step 2: Create Kubernetes Secret**
```bash
# Create namespace
kubectl create namespace cloudflared

# Create secret with tunnel token
kubectl create secret generic cloudflared-token \
  -n cloudflared \
  --from-literal=token='YOUR_TUNNEL_TOKEN_HERE'
```

**Step 3: Configure Tunnel Routes**
```bash
# Route traffic to your services
cloudflared tunnel route dns homelab myapp.example.com
```

### Generic Secrets

For other applications requiring secrets:

```bash
# From literal values
kubectl create secret generic myapp-secret \
  -n myapp \
  --from-literal=username='admin' \
  --from-literal=password='changeme'

# From files
kubectl create secret generic myapp-tls \
  -n myapp \
  --from-file=tls.crt=./cert.pem \
  --from-file=tls.key=./key.pem

# From environment file
kubectl create secret generic myapp-env \
  -n myapp \
  --from-env-file=.env
```

## Recommended: Sealed Secrets

For production-grade secret management, implement Sealed Secrets:

### Install Sealed Secrets Controller

**Step 1: Add sealed-secrets application**

Create `apps/sealed-secrets.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://bitnami-labs.github.io/sealed-secrets
    chart: sealed-secrets
    targetRevision: 2.16.1
    helm:
      values: |
        fullnameOverride: sealed-secrets-controller
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Step 2: Install kubeseal CLI**
```bash
# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar xfz kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# macOS
brew install kubeseal
```

**Step 3: Deploy sealed-secrets**
```bash
git add apps/sealed-secrets.yaml
git commit -m "Add sealed-secrets controller"
git push

# Wait for controller to be ready
kubectl wait --for=condition=available deployment/sealed-secrets-controller \
  -n kube-system --timeout=300s
```

### Using Sealed Secrets

**Create and seal a secret:**
```bash
# Create regular secret (don't apply)
kubectl create secret generic myapp-secret \
  -n myapp \
  --from-literal=api-key='super-secret-key' \
  --dry-run=client -o yaml > /tmp/secret.yaml

# Seal it (encrypts with cluster public key)
kubeseal -f /tmp/secret.yaml -w apps/myapp/sealed-secret.yaml

# Safe to commit encrypted version
git add apps/myapp/sealed-secret.yaml
git commit -m "Add encrypted myapp secret"
git push

# Controller automatically decrypts and creates Secret in cluster
```

**Seal existing secrets:**
```bash
# Export existing secret
kubectl get secret cloudflared-token -n cloudflared -o yaml > /tmp/secret.yaml

# Remove unnecessary fields
yq eval 'del(.metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)' \
  /tmp/secret.yaml > /tmp/secret-clean.yaml

# Seal it
kubeseal -f /tmp/secret-clean.yaml -w apps/cloudflared/sealed-secret.yaml

# Now safe to store in Git
git add apps/cloudflared/sealed-secret.yaml
git commit -m "Add sealed cloudflared secret"
```

**Update sealed secrets:**
```bash
# Create new sealed secret with updated values
kubectl create secret generic myapp-secret \
  -n myapp \
  --from-literal=api-key='new-secret-key' \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > apps/myapp/sealed-secret.yaml

# Commit and push
git add apps/myapp/sealed-secret.yaml
git commit -m "Update myapp secret"
git push
```

## Alternative: External Secrets Operator

For integration with external secret stores (Vault, AWS Secrets Manager, Azure Key Vault):

### Install External Secrets Operator

Create `apps/external-secrets.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.external-secrets.io
    chart: external-secrets
    targetRevision: 0.9.11
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Using External Secrets

```yaml
# Define secret store (example: Vault)
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: myapp
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "myapp"

---
# Define external secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secret
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-secret
  data:
  - secretKey: api-key
    remoteRef:
      key: myapp/config
      property: api_key
```

## Backup Secrets

**⚠️ Store backups securely (encrypted external storage)**

```bash
# Export all secrets from namespace
kubectl get secrets -n myapp -o yaml > myapp-secrets-backup.yaml

# Export specific secret
kubectl get secret cloudflared-token -n cloudflared -o yaml > cloudflared-backup.yaml

# Encrypt backup before storing
# Option 1: GPG
gpg --symmetric --cipher-algo AES256 secrets-backup.yaml

# Option 2: age
age --encrypt --output secrets-backup.yaml.age secrets-backup.yaml

# Store encrypted file in secure location (NOT in Git)
# - External hard drive
# - Encrypted cloud storage (Dropbox, Google Drive with encryption)
# - Password manager with file attachments (1Password, Bitwarden)
```

## Secret Rotation

```bash
# Update secret value
kubectl create secret generic myapp-secret \
  -n myapp \
  --from-literal=api-key='new-rotated-key' \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart pods to pick up new secret
kubectl rollout restart deployment/myapp -n myapp

# Or for sealed secrets, create new sealed secret and push to Git
```

## Best Practices

1. **Never commit plain secrets to Git**
   - Use `.gitignore` to exclude `*.secret.yaml`, `.env`, etc.
   - Use sealed secrets or external secrets for GitOps

2. **Rotate secrets regularly**
   - API keys: every 90 days
   - Certificates: before expiration
   - Passwords: every 180 days

3. **Use least privilege**
   - Create separate secrets per application
   - Limit secret access with RBAC

4. **Backup encrypted**
   - Export secrets regularly
   - Encrypt backups before storing
   - Test restore procedures

5. **Audit secret access**
   - Enable audit logging
   - Monitor secret read operations
   - Alert on suspicious access

## Recovery Scenarios

### Lost all secrets (disaster recovery)

1. Restore from encrypted backup:
```bash
# Decrypt backup
gpg --decrypt secrets-backup.yaml.gpg > secrets-backup.yaml

# Apply secrets
kubectl apply -f secrets-backup.yaml
```

2. If no backup, recreate manually:
```bash
# Recreate each secret (refer to application docs)
kubectl create secret generic cloudflared-token -n cloudflared --from-literal=token='...'
```

### Sealed Secrets controller key lost

⚠️ **Critical**: If you lose the sealed-secrets master key, you cannot decrypt sealed secrets.

**Backup master key:**
```bash
# Export master key
kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealed-secrets-master.key

# Store securely (encrypted external storage)
age --encrypt --output sealed-secrets-master.key.age sealed-secrets-master.key
```

**Restore master key:**
```bash
# Decrypt and restore
age --decrypt sealed-secrets-master.key.age > sealed-secrets-master.key
kubectl apply -f sealed-secrets-master.key
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
```

## Migration Path

Current → Sealed Secrets → External Secrets Operator

1. Start with manual secrets (current state)
2. Implement sealed secrets for GitOps workflow
3. Migrate to ESO when integrating with enterprise secret stores
