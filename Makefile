# Local demo for testing on minikube.
PROFILE       ?= pgha
CPUS          ?= 2
MEMORY        ?= 3072
NS            ?= postgres
CHART         := charts/postgres-ha
STORAGE_CLASS ?= csi-hostpath-sc
MINIKUBE_FLAGS ?=

.PHONY: help up platform s3 db status failover restore lint clean

help:
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

up: ## Minikube cluster: 3 nodes, Calico, CSI addon (multi-node storage)
	minikube start -p $(PROFILE) --nodes 3 --cpus $(CPUS) --memory $(MEMORY) --cni=calico --driver=docker --force
	minikube -p $(PROFILE) addons enable volumesnapshots
	minikube -p $(PROFILE) addons enable csi-hostpath-driver
	kubectl apply -f infra/storageclass-minikube.yaml
	kubectl get nodes

platform: ## MetalLB + cert-manager + operator CNPG + plugin barman-cloud (from the official Helm charts)
	helm repo add metallb https://metallb.github.io/metallb
	helm repo add jetstack https://charts.jetstack.io
	helm repo add cnpg https://cloudnative-pg.github.io/charts
	helm repo update
	helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --set speaker.frr.enabled=false --set frrk8s.enabled=false --wait --timeout 10m
	POOL_RANGE=$$(minikube -p $(PROFILE) ip | awk -F. '{printf "%s.%s.%s.200-%s.%s.%s.220",$$1,$$2,$$3,$$1,$$2,$$3}') \
	  envsubst < infra/metallb-pool.yaml | kubectl apply -f -
	helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --wait
	helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace --wait
	helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud -n cnpg-system --wait

s3: ## S3 for demo backup + bucket + backup-s3 secret with random password
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace storage --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n storage get secret minio-root >/dev/null 2>&1 || \
	  kubectl -n storage create secret generic minio-root \
	    --from-literal=MINIO_ROOT_USER=pgadmin --from-literal=MINIO_ROOT_PASSWORD=$$(openssl rand -hex 16)
	kubectl -n storage apply -f demo/minio.yaml
	kubectl -n storage rollout status deploy/minio --timeout=180s
	kubectl -n storage wait --for=condition=complete job/minio-create-bucket --timeout=180s
	kubectl -n $(NS) delete secret backup-s3 --ignore-not-found
	kubectl -n $(NS) create secret generic backup-s3 \
	  --from-literal=ACCESS_KEY_ID=$$(kubectl -n storage get secret minio-root -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d) \
	  --from-literal=ACCESS_SECRET_KEY=$$(kubectl -n storage get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)

db: ## database implementation (chart postgres-ha with values-minikube.yaml)
	helm upgrade --install pg $(CHART) -n $(NS) -f $(CHART)/values-minikube.yaml
	@echo "Obserwuj: kubectl get cluster -n $(NS) -w"

status: ## status of the cluster, pods, PVCs, services and backups
	kubectl -n $(NS) get cluster,pods,pvc,svc,objectstore,scheduledbackup,backup -o wide

failover: ## Demo - killing the primary node with continuous writes
	NS=$(NS) ./scripts/failover-demo.sh

restore: ## for demo purposes, restore from backup to a new pg-restore cluster
	STORAGE_CLASS=$(STORAGE_CLASS) envsubst < demo/restore-cluster.yaml | kubectl apply -f -
	@echo "Obserwuj: kubectl get cluster -n $(NS) -w"

lint: ## chart validation
	helm lint $(CHART)
	helm lint $(CHART) -f $(CHART)/values-minikube.yaml
	helm template pg $(CHART) -n $(NS) >/dev/null
	helm template pg $(CHART) -n $(NS) -f $(CHART)/values-minikube.yaml >/dev/null

clean: ## cleaning, removing the entire minikube cluster
	minikube delete -p $(PROFILE)
