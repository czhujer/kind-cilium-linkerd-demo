# Set environment variables
export CLUSTER_NAME?=kind-cilium-linkerd
#export CILIUM_VERSION?=1.10.6
export CILIUM_VERSION?=1.11.1
export LINKERD_VERSION?=2.11.1
# for MacOS
CERT_EXPIRY := $(shell sh -c "date -v +3y -j '+%Y-%m-%dT%H:%M:%SZ'")
# for linux
# CERT_EXPIRY := $(shell sh -c "date -d '+8760 hour' +\"%Y-%m-%dT%H:%M:%SZ\"")

.PHONY: kind-create
kind-create:
	kind --version
	kind create cluster --name $(CLUSTER_NAME) --config="kind/kind-config.yaml"

.PHONY: kind-delete
kind-delete:
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: kx-kind
kx-kind:
	kind export kubeconfig --name $(CLUSTER_NAME)

.PHONY: cilium-install
cilium-install:
	# pull image locally
	docker pull quay.io/cilium/cilium:v$(CILIUM_VERSION)
	# Load the image onto the cluster
	kind load docker-image \
 		--name $(CLUSTER_NAME) \
 		quay.io/cilium/cilium:v$(CILIUM_VERSION)
	# Add the Cilium repo
	helm repo add cilium https://helm.cilium.io/
	# install/upgrade the chart
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VERSION) \
	   -f kind/kind-values-cilium-hubble.yaml \
   	   --wait \
	   --namespace kube-system \
	   --set operator.replicas=1 \
	   --set nodeinit.enabled=true \
	   --set kubeProxyReplacement=partial \
	   --set hostServices.enabled=false \
	   --set externalIPs.enabled=true \
	   --set nodePort.enabled=true \
	   --set hostPort.enabled=true \
	   --set bpf.masquerade=false \
	   --set image.pullPolicy=IfNotPresent \
	   --set ipam.mode=kubernetes

.PHONY: generate-certs-for-linkerd
generate-certs-for-linkerd:
	step certificate create \
	  root.linkerd.cluster.local \
	  "./ca.crt" "./ca.key" \
	  --profile root-ca \
	  --no-password --insecure \
	  --force
	step certificate create \
	  identity.linkerd.cluster.local \
	  ./issuer.crt ./issuer.key \
	  --profile intermediate-ca \
	  --not-after 8760h --no-password --insecure \
	  --ca ./ca.crt --ca-key ./ca.key \
	  --force

.PHONY: linkerd-preinstall
linkerd-preinstall:
	kubectl label namespace kube-system config.linkerd.io/admission-webhooks=disabled
	kubectl taint nodes --all node-role.kubernetes.io/master- || true
	helm repo add linkerd https://helm.linkerd.io/stable

.PHONY: linkerd-install-simple
linkerd-install-simple:
	kubens linkerd
	linkerd check --pre && linkerd install | kubectl apply --wait=true -f -
	linkerd check
	linkerd viz install | kubectl apply -f - # on-cluster metrics stack
	linkerd check

# TODO: fix namespace
# https://github.com/linkerd/linkerd2/pull/3413

# https://github.com/BuoyantIO/service-mesh-academy/blob/main/linkerd-in-production/create.sh#L78
.PHONY: linkerd-install-ha
linkerd-install-ha:
	# kubens linkerd
	helm install linkerd2 \
	  --set Namespace=linkerd \
	  --set-file identityTrustAnchorsPEM=./ca.crt \
	  --set-file identity.issuer.tls.crtPEM=./issuer.crt \
	  --set-file identity.issuer.tls.keyPEM=./issuer.key \
	  --set identity.issuer.crtExpiry=$(CERT_EXPIRY) \
	  -f https://raw.githubusercontent.com/linkerd/linkerd2/stable-$(LINKERD_VERSION)/charts/linkerd2/values-ha.yaml \
	  --version $(LINKERD_VERSION) \
	  linkerd/linkerd2

#resource "helm_release" "linkerd_viz" {
#  name       = "linkerd-viz"
#  chart      = "linkerd-viz"
#  namespace  = "linkerd"
#  repository = "https://helm.linkerd.io/stable"
#  version    = "2.10.2"
#  set {
#    name  = "linkerdVersion"
#    value = "stable-2.10.2"
#  }
#}

.PHONY: linkerd-uninstall-simple
linkerd-uninstall-simple:
	linkerd viz uninstall | kubectl delete -f -
	linkerd uninstall | kubectl delete -f -

.PHONY: linkerd-uninstall-ha
linkerd-uninstall-ha:
	helm un linkerd2 -n linkerd

.PHONY: k8s-apply
k8s-apply:
	kubectl get ns cilium-linkerd 1>/dev/null 2>/dev/null || kubectl create ns cilium-linkerd
	kubectl apply -k k8s/podinfo -n cilium-linkerd
	kubectl apply -f k8s/client
	kubectl apply -f k8s/networkpolicy

.PHONY: check-status
check-status:
	linkerd top deployment/podinfo --namespace cilium-linkerd
	linkerd tap deployment/client --namespace cilium-linkerd
	kubectl exec deploy/client -n cilium-linkerd -c client -- curl -s podinfo:9898

.PHONY: ambassador-install
ambassador-install:
	helm repo add datawire https://www.getambassador.io
	helm install ambassador --namespace ambassador datawire/ambassador \
		--create-namespace
