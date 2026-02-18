# Secrets Management Guide

This document explains the complete secrets management strategy for your HomeLab.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start with Infisical](#quick-start-with-infisical)
- [Infisical Kubernetes Operator](#infisical-kubernetes-operator)
- [Bootstrap Secrets](#bootstrap-secrets)
- [Secret Rotation](#secret-rotation)
- [Backup and Recovery](#backup-and-recovery)
- [Migration Guides](#migration-guides)
- [Best Practices](#best-practices)

## Overview

This homelab uses a **layered approach** to secrets management:

1. **Infisical** - Primary secrets management platform (source of truth)
2. **Infisical Kubernetes Operator** - Syncs secrets from Infisical to Kubernetes
3. **Manual Kubernetes Secrets** - Only for bootstrap/infrastructure secrets

### Why This Approach?

| Feature | Manual K8s Secrets | Infisical + Operator |
|---------|-------------------|----------------------|
| GitOps-friendly | ❌ (can't commit to Git) | ✅ (CRDs in Git, not secrets) |
| Centralized management | ❌ (scattered across cluster) | ✅ (single UI/API) |
| Audit trail | ❌ | ✅ |
| Version control | ❌ | ✅ |
| Auto-sync | ❌ | ✅ |
| Environment isolation | ❌ | ✅ (dev/staging/prod) |
| Team collaboration | ❌ | ✅ |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         Infisical                            │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  PostgreSQL                                              ││
│  │  - Encrypted secret storage                             ││
│  │  - Audit logs                                           ││
│  │  - Version history                                      ││
│  └─────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Redis                                                   ││
│  │  - Caching layer                                        ││
│  │  - Session management                                   ││
│  └─────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Web UI / API                                           ││
│  │  - Manage secrets via browser                           ││
│  │  - Machine Identity authentication                      ││
│  │  - Project & environment organization                   ││
│  └─────────────────────────────────────────────────────────┘│
└──────────────────┬───────────────────────────────────────────┘
                   │
                   │ API Calls (Universal Auth)
                   │
┌──────────────────▼───────────────────────────────────────────┐
│         Infisical Kubernetes Operator                        │
│  - Watches InfisicalSecret CRDs                              │
│  - Authenticates with Machine Identity                       │
│  - Fetches secrets from Infisical                            │
│  - Creates/updates Kubernetes Secrets                        │
│  - Auto-syncs every N seconds                                │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   │ Creates/Updates
                   │
┌──────────────────▼───────────────────────────────────────────┐
│              Kubernetes Secrets                               │
│  - Standard K8s Secret objects                                │
│  - Used by applications (env vars, volumes)                   │
│  - Automatically updated on Infisical changes                 │
└───────────────────────────────────────────────────────────────┘
```

## Quick Start with Infisical

### 1. Access Infisical

Navigate to `https://secrets.yourdomain.com` and create your admin account.

### 2. Create a Project

1. Click **"New Project"**
2. Name: e.g., `homelab-apps`
3. Environments are created automatically:
   - Development (`dev`)
   - Staging (`staging`)
   - Production (`prod`)

### 3. Add Secrets

1. Select your project
2. Choose environment (e.g., `prod`)
3. Click **"Add Secret"**
4. Enter key-value pairs:
   ```
   DATABASE_URL = postgresql://user:pass@host:5432/db
   API_KEY = your-api-key-here
   SMTP_PASSWORD = email-password
   ```
5. Click **"Save"**

### 4. Create Machine Identity (for Operator)

1. Go to **Project Settings** → **Access Control** → **Machine Identities**
2. Click **"Create Identity"**
   - Name: `kubernetes-operator`
   - Organization Role: Member or Admin
3. Click **"Create"**

### 5. Add Universal Auth

1. Click on your newly created identity
2. Go to **"Auth Methods"** tab
3. Click **"Add Auth Method"** → **"Universal Auth"**
4. Configure:
   - Access Token TTL: `2592000` (30 days)
   - Access Token Max TTL: `2592000`
   - Access Token Trusted IPs: `0.0.0.0/0` (or restrict to cluster CIDR)
5. Click **"Add"**
6. **IMPORTANT:** Copy and save:
   - Client ID (e.g., `bcf04e26-edab-4c4f-920a-ec04310405df`)
   - Client Secret (e.g., `6fc318e9eaa241857653c363f403f3df136d555bf0dcfa3ae8855a1f2faf977e`)

### 6. Grant Project Access

1. Still in Machine Identity settings
2. Go to **"Project Access"** tab
3. Click **"Add Project"**
4. Select your project (e.g., `homelab-apps`)
5. Choose environments: All or specific ones
6. Set role: **Viewer** (read-only) or higher if you need push capability
7. Click **"Add"**

### 7. Create Kubernetes Auth Secret

```bash
kubectl create secret generic infisical-universal-auth \
  -n default \
  --from-literal=clientId='YOUR_CLIENT_ID' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET'
```

## Infisical Kubernetes Operator

### How It Works

The operator watches for `InfisicalSecret` custom resources and automatically:
1. Authenticates with Infisical using Machine Identity
2. Fetches secrets from specified project/environment
3. Creates/updates Kubernetes Secret objects
4. Re-syncs periodically to catch updates

### Creating an InfisicalSecret

**Example:** Sync secrets from `homelab-apps` project, `prod` environment

Create `apps/myapp/infisical-secret.yaml`:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: myapp-secrets
  namespace: myapp
spec:
  # How often to check for updates (in seconds)
  resyncInterval: 60

  authentication:
    universalAuth:
      secretsScope:
        # Project slug (from URL: /project/<project-slug>)
        projectSlug: homelab-apps-xyz123

        # Environment: dev, staging, or prod
        envSlug: prod

        # Path within environment (/ = root)
        secretsPath: "/"

      credentialsRef:
        # Reference to auth secret created above
        secretName: infisical-universal-auth
        secretNamespace: default

  managedSecretReference:
    # Name of Kubernetes Secret to create
    secretName: myapp-secrets

    # Namespace for the secret
    secretNamespace: myapp

    # What happens if InfisicalSecret is deleted
    # "Orphan" = keep secret, "Owner" = delete secret
    creationPolicy: "Orphan"
```

Add to kustomization:
```yaml
# apps/myapp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - infisical-secret.yaml
```

### Using Synced Secrets in Applications

**Option 1: Environment Variables**

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

        # Individual env vars
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: DATABASE_URL

        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: API_KEY

        # Or load all secrets as env vars
        envFrom:
        - secretRef:
            name: myapp-secrets
```

**Option 2: Volume Mounts (for files)**

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

        volumeMounts:
        - name: secrets
          mountPath: "/etc/secrets"
          readOnly: true

        # Secrets available as files:
        # /etc/secrets/DATABASE_URL
        # /etc/secrets/API_KEY

      volumes:
      - name: secrets
        secret:
          secretName: myapp-secrets
```

**Option 3: Specific Files**

```yaml
volumes:
- name: db-config
  secret:
    secretName: myapp-secrets
    items:
    - key: DATABASE_URL
      path: database.conf
      mode: 0400  # Read-only for owner

# Mounts as: /etc/config/database.conf
```

### Advanced Operator Features

**Custom Secret Templates**

Transform secrets before creating Kubernetes Secret:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: myapp-secrets
  namespace: myapp
spec:
  resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: homelab-apps-xyz123
        envSlug: prod
        secretsPath: "/"
      credentialsRef:
        secretName: infisical-universal-auth
        secretNamespace: default

  managedSecretReference:
    secretName: myapp-secrets
    secretNamespace: myapp
    creationPolicy: "Orphan"

    # Custom template
    template:
      # Include all secrets from Infisical
      includeAllSecrets: true

      # Add computed/derived secrets
      data:
        # Combine multiple secrets
        FULL_DATABASE_URL: "postgresql://{{ .DB_USER.Value }}:{{ .DB_PASSWORD.Value }}@{{ .DB_HOST.Value }}:{{ .DB_PORT.Value }}/{{ .DB_NAME.Value }}"

        # Reference other secrets
        REDIS_CONNECTION: "redis://:{{ .REDIS_PASSWORD.Value }}@redis:6379"
```

**Multiple Environments**

```yaml
# Development
---
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: myapp-dev-secrets
  namespace: myapp-dev
spec:
  resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: homelab-apps-xyz123
        envSlug: dev  # Development environment
        secretsPath: "/"
      credentialsRef:
        secretName: infisical-universal-auth
        secretNamespace: default
  managedSecretReference:
    secretName: myapp-secrets
    secretNamespace: myapp-dev

---
# Production
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: myapp-prod-secrets
  namespace: myapp-prod
spec:
  resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: homelab-apps-xyz123
        envSlug: prod  # Production environment
        secretsPath: "/"
      credentialsRef:
        secretName: infisical-universal-auth
        secretNamespace: default
  managedSecretReference:
    secretName: myapp-secrets
    secretNamespace: myapp-prod
```

### Verifying Operator Sync

```bash
# Check InfisicalSecret status
kubectl get infisicalsecret -n myapp

# Detailed status
kubectl describe infisicalsecret myapp-secrets -n myapp

# Check events
kubectl get events -n myapp | grep InfisicalSecret

# Verify synced Kubernetes Secret exists
kubectl get secret myapp-secrets -n myapp

# View secret keys (not values)
kubectl get secret myapp-secrets -n myapp -o jsonpath='{.data}' | jq 'keys'

# View secret value (decode base64)
kubectl get secret myapp-secrets -n myapp -o jsonpath='{.data.API_KEY}' | base64 -d
```

## Bootstrap Secrets

Some secrets are needed **before** Infisical is running (chicken-and-egg problem). These must be created manually.

### Required Bootstrap Secrets

#### 1. Cloudflare Tunnel Token

```bash
kubectl create namespace cloudflared
kubectl create secret generic cloudflared-token \
  -n cloudflared \
  --from-literal=token='YOUR_CLOUDFLARE_TUNNEL_TOKEN'
```

#### 2. Infisical Database Credentials

```bash
# Generate secure passwords
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 16)  # 16 bytes = 32 hex chars
AUTH_SECRET=$(openssl rand -base64 32)

# Create secrets
kubectl create secret generic db-credentials -n infisical \
  --from-literal=password="$DB_PASSWORD"

kubectl create secret generic redis-credentials -n infisical \
  --from-literal=password="$REDIS_PASSWORD"

kubectl create secret generic infisical-secrets -n infisical \
  --from-literal=ENCRYPTION_KEY="$ENCRYPTION_KEY" \
  --from-literal=AUTH_SECRET="$AUTH_SECRET" \
  --from-literal=SITE_URL='https://secrets.yourdomain.com' \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:${DB_PASSWORD}@postgres:5432/infisical" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379"

# CRITICAL: Backup these credentials!
cat > ~/infisical-bootstrap-secrets.txt <<EOF
Database Password: $DB_PASSWORD
Redis Password: $REDIS_PASSWORD
Encryption Key: $ENCRYPTION_KEY
Auth Secret: $AUTH_SECRET
EOF

chmod 600 ~/infisical-bootstrap-secrets.txt

# Encrypt and store safely
gpg --symmetric --cipher-algo AES256 ~/infisical-bootstrap-secrets.txt
# Move encrypted file to secure storage
```

#### 3. Infisical Operator Authentication

```bash
# After creating Machine Identity in Infisical UI
kubectl create secret generic infisical-universal-auth \
  -n default \
  --from-literal=clientId='YOUR_CLIENT_ID' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET'
```

#### 4. Argo CD GitHub SSH Key

```bash
kubectl create secret generic homelab-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:0xAaCE/HomeLab.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519 \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret homelab-repo -n argocd \
  argocd.argoproj.io/secret-type=repository
```

### Backup Bootstrap Secrets

```bash
# Export all bootstrap secrets
kubectl get secret cloudflared-token -n cloudflared -o yaml > bootstrap-secrets.yaml
kubectl get secret db-credentials redis-credentials infisical-secrets -n infisical -o yaml >> bootstrap-secrets.yaml
kubectl get secret infisical-universal-auth -n default -o yaml >> bootstrap-secrets.yaml
kubectl get secret homelab-repo -n argocd -o yaml >> bootstrap-secrets.yaml

# Encrypt
gpg --symmetric --cipher-algo AES256 bootstrap-secrets.yaml

# Store encrypted file securely (NOT in Git)
mv bootstrap-secrets.yaml.gpg ~/secure-backup/
rm bootstrap-secrets.yaml

# Also save plaintext passwords separately
# (Already saved in ~/infisical-bootstrap-secrets.txt)
```

## Secret Rotation

### Rotating Infisical Secrets (Managed by Operator)

**This is automatic!** Just update secrets in Infisical UI:

1. Go to Infisical project
2. Navigate to environment
3. Click secret → Edit
4. Update value → Save
5. Operator syncs within `resyncInterval` seconds
6. Kubernetes Secret is automatically updated

**Restart pods to pick up changes:**

```bash
# Option 1: Restart deployment
kubectl rollout restart deployment/myapp -n myapp

# Option 2: Delete pods (ReplicaSet recreates them)
kubectl delete pods -n myapp -l app=myapp
```

**Pro tip:** Use `reloader` for automatic pod restarts on secret changes:
- [Stakater Reloader](https://github.com/stakater/Reloader)

### Rotating Bootstrap Secrets

#### Cloudflare Tunnel Token

```bash
# Generate new token in Cloudflare Dashboard
# Update secret
kubectl create secret generic cloudflared-token \
  -n cloudflared \
  --from-literal=token='NEW_TUNNEL_TOKEN' \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart cloudflared
kubectl rollout restart deployment/cloudflared -n cloudflared
```

#### Infisical Database Passwords

**⚠️ Complex - requires downtime**

```bash
# 1. Scale down Infisical
kubectl scale deployment -n infisical --replicas=0 \
  $(kubectl get deployment -n infisical -o name | grep infisical-standalone)

# 2. Generate new passwords
NEW_DB_PASSWORD=$(openssl rand -hex 32)
NEW_REDIS_PASSWORD=$(openssl rand -hex 32)

# 3. Update PostgreSQL password
kubectl exec -n infisical postgres-0 -- psql -U infisical -d infisical -c \
  "ALTER USER infisical WITH PASSWORD '$NEW_DB_PASSWORD';"

# 4. Update Redis password
kubectl exec -n infisical $(kubectl get pod -n infisical -l app=redis -o name) -- \
  redis-cli CONFIG SET requirepass "$NEW_REDIS_PASSWORD"

# 5. Update secrets
kubectl patch secret db-credentials -n infisical \
  --type merge -p "{\"data\":{\"password\":\"$(echo -n $NEW_DB_PASSWORD | base64)\"}}"

kubectl patch secret redis-credentials -n infisical \
  --type merge -p "{\"data\":{\"password\":\"$(echo -n $NEW_REDIS_PASSWORD | base64)\"}}"

kubectl patch secret infisical-secrets -n infisical \
  --type merge -p "{\"data\":{\
    \"DB_CONNECTION_URI\":\"$(echo -n postgresql://infisical:$NEW_DB_PASSWORD@postgres:5432/infisical | base64)\",\
    \"REDIS_URL\":\"$(echo -n redis://:$NEW_REDIS_PASSWORD@redis:6379 | base64)\"\
  }}"

# 6. Scale up Infisical
kubectl scale deployment -n infisical --replicas=1 \
  $(kubectl get deployment -n infisical -o name | grep infisical-standalone)

# 7. Verify
kubectl logs -n infisical -l app.kubernetes.io/name=infisical-standalone
```

#### Infisical Operator Credentials

```bash
# 1. Regenerate in Infisical UI:
#    - Go to Machine Identity
#    - Auth Methods → Universal Auth → Regenerate Client Secret
#    - Copy new Client Secret

# 2. Update Kubernetes secret
kubectl create secret generic infisical-universal-auth -n default \
  --from-literal=clientId='SAME_CLIENT_ID' \
  --from-literal=clientSecret='NEW_CLIENT_SECRET' \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart operator to pick up new credentials
kubectl rollout restart deployment -n infisical-operator-system \
  $(kubectl get deployment -n infisical-operator-system -o name)
```

## Backup and Recovery

### What to Backup

1. **Infisical PostgreSQL Database** (contains all secrets)
2. **Bootstrap Kubernetes Secrets**
3. **Infisical Encryption Keys**

### Backup Procedures

#### 1. Infisical Database Backup

```bash
# Full PostgreSQL dump
kubectl exec -n infisical postgres-0 -- \
  pg_dump -U infisical infisical | \
  gzip > infisical-backup-$(date +%Y%m%d-%H%M%S).sql.gz

# Encrypt
gpg --symmetric --cipher-algo AES256 infisical-backup-*.sql.gz

# Store securely
mv infisical-backup-*.sql.gz.gpg ~/secure-backup/
```

**Automated backup (cron):**

```bash
# Create backup script
cat > ~/backup-infisical.sh <<'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=~/secure-backup
mkdir -p $BACKUP_DIR

# Backup database
kubectl exec -n infisical postgres-0 -- \
  pg_dump -U infisical infisical | \
  gzip > /tmp/infisical-backup-$DATE.sql.gz

# Encrypt
gpg --symmetric --cipher-algo AES256 --batch --yes \
  --passphrase-file ~/.gpg-pass \
  /tmp/infisical-backup-$DATE.sql.gz

# Move to secure location
mv /tmp/infisical-backup-$DATE.sql.gz.gpg $BACKUP_DIR/

# Clean up old backups (keep last 30 days)
find $BACKUP_DIR -name "infisical-backup-*.sql.gz.gpg" -mtime +30 -delete

# Cleanup temp
rm /tmp/infisical-backup-$DATE.sql.gz
EOF

chmod +x ~/backup-infisical.sh

# Add to cron (daily at 2 AM)
crontab -e
# Add line:
# 0 2 * * * /home/yourusername/backup-infisical.sh >> /home/yourusername/backup-infisical.log 2>&1
```

#### 2. Bootstrap Secrets Backup

Already covered in [Bootstrap Secrets](#bootstrap-secrets) section.

### Recovery Procedures

#### Restore Infisical Database

```bash
# 1. Decrypt backup
gpg --decrypt infisical-backup-20260218-140000.sql.gz.gpg | gunzip > restore.sql

# 2. Scale down Infisical
kubectl scale deployment -n infisical --replicas=0 \
  $(kubectl get deployment -n infisical -o name | grep infisical-standalone)

# 3. Restore database
kubectl exec -i -n infisical postgres-0 -- psql -U infisical infisical < restore.sql

# 4. Scale up Infisical
kubectl scale deployment -n infisical --replicas=1 \
  $(kubectl get deployment -n infisical -o name | grep infisical-standalone)

# 5. Verify
kubectl logs -n infisical -l app.kubernetes.io/name=infisical-standalone

# 6. Clean up
rm restore.sql
```

#### Restore Bootstrap Secrets

```bash
# Decrypt
gpg --decrypt bootstrap-secrets.yaml.gpg > bootstrap-secrets.yaml

# Apply
kubectl apply -f bootstrap-secrets.yaml

# Clean up
rm bootstrap-secrets.yaml
```

#### Full Disaster Recovery

See main [README.md - Backup and Disaster Recovery](./README.md#backup-and-disaster-recovery) section.

## Migration Guides

### From Manual Secrets to Infisical

**Step 1: Export existing secrets**

```bash
# Export secret values
kubectl get secret myapp-secret -n myapp -o json | \
  jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"' \
  > myapp-secrets.env
```

**Step 2: Import to Infisical**

1. Go to Infisical Web UI
2. Select project and environment
3. Manually add secrets (or use Infisical CLI/API for bulk import)

**Step 3: Create InfisicalSecret CRD**

Follow [Infisical Kubernetes Operator](#infisical-kubernetes-operator) section.

**Step 4: Verify sync**

```bash
# Check operator created the secret
kubectl get secret myapp-secrets -n myapp -o yaml

# Compare with original
diff <(kubectl get secret myapp-secret-old -n myapp -o json | jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"' | sort) \
     <(kubectl get secret myapp-secrets -n myapp -o json | jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"' | sort)
```

**Step 5: Update application to use new secret**

```yaml
# Change from:
  secretKeyRef:
    name: myapp-secret-old

# To:
  secretKeyRef:
    name: myapp-secrets
```

**Step 6: Clean up old secret**

```bash
kubectl delete secret myapp-secret-old -n myapp
```

## Best Practices

### Security

1. **Rotate secrets regularly**
   - API keys: Every 90 days
   - Machine identities: Every 180 days
   - Database passwords: Annually or on breach
   - Encryption keys: Only when compromised

2. **Use least privilege**
   - Machine identities should have read-only access (Viewer role) unless write is needed
   - Restrict trusted IPs when possible
   - Separate identities per application/namespace

3. **Encrypt all backups**
   - Use GPG with strong passphrase
   - Store encrypted backups in multiple locations
   - Test restore procedures regularly

4. **Audit secret access**
   - Review Infisical audit logs monthly
   - Monitor for suspicious activity
   - Set up alerts for secret changes in production

### Organization

1. **Use consistent naming**
   - Projects: `homelab-<purpose>` (e.g., `homelab-apps`, `homelab-infra`)
   - Secrets: `SCREAMING_SNAKE_CASE` (e.g., `DATABASE_URL`, `API_KEY`)
   - InfisicalSecret CRDs: `<app>-secrets` (e.g., `myapp-secrets`)

2. **Environment separation**
   - Use Infisical environments: dev, staging, prod
   - Never share secrets across environments
   - Test changes in dev first

3. **Document secrets**
   - Add descriptions in Infisical UI
   - Include examples/format in comments
   - Document rotation procedures

### Operations

1. **Monitor sync status**
   ```bash
   # Check all InfisicalSecrets
   kubectl get infisicalsecret -A

   # Alert on sync failures
   kubectl get infisicalsecret -A -o json | \
     jq -r '.items[] | select(.status.conditions[] | .type=="secrets.infisical.com/ReadyToSyncSecrets" and .status=="False") | "\(.metadata.namespace)/\(.metadata.name)"'
   ```

2. **Test secret changes**
   - Always test in dev environment first
   - Verify application behavior after secret updates
   - Have rollback plan ready

3. **Automate backups**
   - Daily PostgreSQL dumps
   - Weekly full cluster snapshots
   - Monthly disaster recovery drills

## Troubleshooting

See main [README.md - Troubleshooting](./README.md#troubleshooting) section for:
- Infisical pod issues
- Operator sync failures
- Database connection problems
- Authentication errors

## Resources

- [Infisical Documentation](https://infisical.com/docs)
- [Infisical Kubernetes Operator](https://infisical.com/docs/integrations/platforms/kubernetes/overview)
- [InfisicalSecret CRD Reference](https://infisical.com/docs/integrations/platforms/kubernetes/infisical-secret-crd)
- [Machine Identities Guide](https://infisical.com/docs/documentation/platform/identities/machine-identities)
