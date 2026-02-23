#!/bin/bash
set -euo pipefail

# AWS Lightweight Environment Setup
# Installs k3s, cloudflared, and code-server (no ArgoCD)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== Installing k3s ==="
curl -sfL https://get.k3s.io | sh -

echo "Waiting for k3s to be ready..."
sudo k3s kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Make kubectl accessible without sudo
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
export KUBECONFIG=~/.kube/config

# Prompt for cloudflared tunnel token
echo ""
read -rsp "Enter cloudflared tunnel token: " TUNNEL_TOKEN
echo ""

if [ -z "$TUNNEL_TOKEN" ]; then
  echo "Error: tunnel token cannot be empty"
  exit 1
fi

# Deploy cloudflared
echo "=== Deploying cloudflared ==="
kubectl apply -k "$REPO_ROOT/apps/cloudflared"
kubectl -n cloudflared create secret generic cloudflared-token \
  --from-literal=token="$TUNNEL_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Waiting for cloudflared to be ready..."
kubectl -n cloudflared wait --for=condition=Available deployment/cloudflared --timeout=120s

# Deploy code-server (AWS overlay)
echo "=== Deploying code-server ==="
kubectl apply -k "$REPO_ROOT/environments/aws/code-server"

echo "Waiting for code-server to be ready..."
kubectl -n code-server wait --for=condition=Available deployment/code-server --timeout=120s

echo ""
echo "=== Deployment Complete ==="
echo ""
kubectl get pods -A
echo ""
echo "Next steps:"
echo "  1. In Cloudflare Zero Trust, add a private network route for this instance's VPC CIDR"
echo "  2. Connect via WARP and SSH into the instance"
echo "  3. code-server is available at its ClusterIP (check: kubectl -n code-server get svc)"
