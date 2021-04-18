.PHONY: kind-create
kind-create:
#	kubectl cp k3s-server-559ddfc47d-56zbl:/output/kubeconfig.yaml ~/.kube/config-szn-uacl-core-test2-k3s
#	chmod 600 /home/czhujer/.kube/config-szn-uacl-core-test2-k3s
#	sed -i 's/127.0.0.1:6443/10.247.128.53:6443/' ~/.kube/config-szn-uacl-core-test2-k3s
#	export KUBECONFIG=~/.kube/config-szn-uacl-core-test2-k3s
#	kubectl cluster-info
	kind --version
	kind create cluster --config="kind/kind-config.yaml"

.PHONY: kind-delete
kind-delete:
	kind delete cluster

.PHONY: kx-kind
kx-kind:
	kind export kubeconfig

.PHONY: cilium-install
cilium-install:
	# pull image locally
	docker pull cilium/cilium:v1.9.5
	# Add the Cilium repo
	helm repo add cilium https://helm.cilium.io/
	# Load the image onto the cluster
	kind load docker-image cilium/cilium:v1.9.5

	helm install cilium cilium/cilium --version 1.9.5 \
	   --namespace kube-system \
	   --set nodeinit.enabled=true \
	   --set kubeProxyReplacement=partial \
	   --set hostServices.enabled=false \
	   --set externalIPs.enabled=true \
	   --set nodePort.enabled=true \
	   --set hostPort.enabled=true \
	   --set bpf.masquerade=false \
	   --set image.pullPolicy=IfNotPresent \
	   --set ipam.mode=kubernetes

.PHONY: linkerd-install
linkerd-install:
	linkerd check --pre && linkerd install | kubectl apply --wait=true -f -
	linkerd check
	linkerd viz install | kubectl apply -f - # on-cluster metrics stack
	linkerd check

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
	kubectl exec deploy/client -n cilium-linkerd -- curl -s podinfo:9898

.PHONY: ambassador-install
ambassador-install:
	helm repo add datawire https://www.getambassador.io
	helm install ambassador --namespace ambassador datawire/ambassador \
		--create-namespace
