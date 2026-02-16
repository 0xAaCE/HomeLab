# Infisical - Open Source Secrets Manager

Infisical is an open-source secrets management platform for managing environment variables, API keys, and other sensitive data across your applications.

## Components

- **PostgreSQL** - Primary database for storing encrypted secrets
- **Redis** - Caching and session management
- **Infisical Backend** - Main application server

## Prerequisites

Before deploying, you need to create the secrets manually:

```bash
# Generate random encryption keys
ENCRYPTION_KEY=$(openssl rand -base64 32)
AUTH_SECRET=$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -base64 24)
REDIS_PASSWORD=$(openssl rand -base64 24)

# Create the secret
kubectl create secret generic infisical-secrets \
  -n infisical \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --from-literal=auth-secret="$AUTH_SECRET" \
  --from-literal=db-password="$DB_PASSWORD" \
  --from-literal=redis-password="$REDIS_PASSWORD"
```

**Important:** Save these values securely! You'll need them for disaster recovery.

## Deployment

After creating the secrets, Argo CD will automatically deploy Infisical:

```bash
# Verify deployment
kubectl get pods -n infisical

# Check logs
kubectl logs -n infisical -l app=infisical --tail=50
```

## Access

- **URL:** https://secrets.0xaace.xyz (via Cloudflare Tunnel)
- **Service:** `infisical.infisical.svc.cluster.local:8080`

## Initial Setup

1. Navigate to https://secrets.0xaace.xyz
2. Create your first admin account
3. Create an organization
4. Start creating projects and secrets

## Configuration

The deployment uses the following environment variables:

- `SITE_URL`: https://secrets.0xaace.xyz
- `DB_CONNECTION_URI`: PostgreSQL connection string
- `REDIS_URL`: Redis connection string
- `ENCRYPTION_KEY`: Used to encrypt secrets at rest
- `AUTH_SECRET`: Used for JWT token signing
- `TELEMETRY_ENABLED`: Disabled for privacy

## Storage

PostgreSQL uses a 5Gi PersistentVolumeClaim for data persistence.

**Backup recommendation:** Regularly backup the PostgreSQL database:

```bash
# Create backup
kubectl exec -n infisical postgres-0 -- pg_dump -U infisical infisical > infisical-backup.sql

# Restore backup
kubectl exec -i -n infisical postgres-0 -- psql -U infisical infisical < infisical-backup.sql
```

## Troubleshooting

### Pods not starting

```bash
# Check if secrets exist
kubectl get secret infisical-secrets -n infisical

# Check pod logs
kubectl logs -n infisical -l app=infisical
kubectl logs -n infisical -l app=postgres
kubectl logs -n infisical -l app=redis
```

### Database connection issues

```bash
# Check PostgreSQL is ready
kubectl exec -n infisical postgres-0 -- psql -U infisical -c "SELECT 1"

# Check Redis is ready
kubectl exec -n infisical deploy/redis -- redis-cli -a $REDIS_PASSWORD ping
```

### Reset admin password

If you forget your admin password, you'll need to reset it via the database. Contact Infisical support or check their documentation for the procedure.

## Upgrading

To upgrade Infisical:

1. Update the image tag in `infisical.yaml`
2. Commit and push changes
3. Argo CD will automatically sync

```bash
# Check available versions
# https://hub.docker.com/r/infisical/infisical/tags

# Update image tag
# image: infisical/infisical:v0.66.2-postgres
```

## Security Notes

- All secrets are encrypted at rest using the `ENCRYPTION_KEY`
- Never commit the `infisical-secrets` Secret to Git
- Backup encryption keys securely (password manager, encrypted storage)
- Use strong passwords for database and Redis
- Consider enabling 2FA for all users after initial setup

## Resources

- CPU Request: 200m, Limit: 500m (Infisical)
- Memory Request: 256Mi, Limit: 512Mi (Infisical)
- Storage: 5Gi (PostgreSQL)

Adjust based on your usage and available resources.
