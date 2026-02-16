#!/bin/bash
set -euo pipefail

# HomeLab Setup Script
# Installs k3s and Argo CD

ARGOCD_VERSION="v3.3.0"

echo "=== Installing k3s ==="
curl -sfL https://get.k3s.io | sh -

# Wait for k3s to be ready
echo "Waiting for k3s to be ready..."
sudo k3s kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Make kubectl accessible without sudo
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
export KUBECONFIG=~/.kube/config

echo "=== Installing Argo CD ${ARGOCD_VERSION} ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

echo "Waiting for Argo CD to be ready..."
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

echo "=== Setup Complete ==="
echo ""
echo "Get Argo CD admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Access Argo CD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Then open https://localhost:8080"
