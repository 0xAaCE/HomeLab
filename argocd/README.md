# Argo CD Configuration

This directory contains Argo CD bootstrap and configuration files.

## Files

- `app-of-apps.yaml` - Root application that manages all applications in the `apps/` directory
- `config/argocd-cmd-params-cm.yaml` - Argo CD command parameters configuration

## Initial Setup

### 1. Install Argo CD

Run the setup script:
```bash
./scripts/setup.sh
```

### 2. Configure SSH Access to GitHub

Argo CD needs SSH access to clone your private repository:

```bash
# Create secret with your SSH private key
kubectl create secret generic homelab-repo \
  -n argocd \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519 \
  --dry-run=client -o yaml | kubectl apply -f -

# Label it as repository secret
kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository

# Add repository URL
kubectl patch secret homelab-repo -n argocd --type merge -p '{
  "stringData": {
    "type": "git",
    "url": "git@github.com:0xAaCE/HomeLab.git"
  }
}'
```

Or use the one-liner:
```bash
kubectl create secret generic homelab-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:0xAaCE/HomeLab.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519 \
  --dry-run=client -o yaml | \
  kubectl apply -f - && \
  kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository
```

### 3. Apply Argo CD Configuration

```bash
# Apply command parameters (enables insecure mode for reverse proxy)
kubectl apply -f argocd/config/argocd-cmd-params-cm.yaml

# Restart server to pick up config
kubectl rollout restart deployment argocd-server -n argocd
```

### 4. Bootstrap GitOps

```bash
# Apply app-of-apps to start managing all applications
kubectl apply -f argocd/app-of-apps.yaml
```

## Configuration Details

### Insecure Mode

The `server.insecure: "true"` setting is **required** when running Argo CD behind a reverse proxy (like Cloudflare Tunnel, Traefik, or Nginx). This disables TLS on the Argo CD server since the reverse proxy handles TLS termination.

**Important:** When using insecure mode:
- Argo CD listens on port **80** (HTTP)
- Update your reverse proxy to point to `http://argocd-server.argocd.svc.cluster.local:80`
- The reverse proxy should handle HTTPS/TLS

### Cloudflare Tunnel Configuration

If using Cloudflare Tunnel, configure your public hostname:

```yaml
# In Cloudflare Dashboard: Zero Trust → Networks → Tunnels
hostname: argo.yourdomain.com
service: http://argocd-server.argocd.svc.cluster.local:80
originRequest:
  disableChunkedEncoding: true
```

## Access Argo CD

### Get Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Port Forward (for local access)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Open http://localhost:8080
```

### Via Cloudflare Tunnel

Access via your configured domain (e.g., `https://argo.yourdomain.com`)

## Troubleshooting

### ERR_TOO_MANY_REDIRECTS

If you get redirect loops:
1. Ensure `server.insecure: "true"` is set in `argocd-cmd-params-cm`
2. Restart argocd-server: `kubectl rollout restart deployment argocd-server -n argocd`
3. Ensure your reverse proxy points to port **80**, not 443
4. Example: `http://argocd-server.argocd.svc.cluster.local:80`

### Repository Access Issues

If apps show "ComparisonError" with SSH errors:
1. Verify SSH secret exists: `kubectl get secret homelab-repo -n argocd`
2. Check secret has correct label: `kubectl get secret homelab-repo -n argocd -o yaml | grep argocd.argoproj.io/secret-type`
3. Verify SSH key has access to GitHub repository

### App Won't Sync

```bash
# Check application status
kubectl get application -n argocd

# View detailed error
kubectl describe application <app-name> -n argocd

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50
```
