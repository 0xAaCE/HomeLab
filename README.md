# HomeLab

k3s + Argo CD homelab setup for GitOps-based infrastructure management.

## Quick Start

```bash
# Fresh install
./scripts/setup.sh

# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Access Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Structure

```
├── scripts/
│   └── setup.sh          # k3s + Argo CD installation
├── argocd/
│   └── app-of-apps.yaml  # Root application (bootstrap GitOps)
└── apps/                  # Application manifests managed by Argo CD
```

## Bootstrap GitOps

After running `setup.sh`, apply the app-of-apps to let Argo CD manage itself:

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

Then add Application manifests to `apps/` and push — Argo CD will sync automatically.

## Components

- **k3s**: Lightweight Kubernetes
- **Argo CD v3.3.0**: GitOps continuous delivery
