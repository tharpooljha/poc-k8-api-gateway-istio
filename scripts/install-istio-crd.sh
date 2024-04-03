#!/bin/sh
# minikube start
export PILOT_ENABLE_ALPHA_GATEWAY_API=true
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=444631bfe06f3bcca5d0eadf1857eac1d369421d" | kubectl apply -f -; }


sleep 10s
istioctl install --set profile=minimal -y
kubectl create namespace istio-ingress
kubectl apply -f gateway.yaml --namespace istio-ingress
kubectl  apply -f httproute.yaml --namespace istio-ingress
kubectl wait --namespace istio-ingress --for=condition=programmed gateways.gateway.networking.k8s.io gateway
export INGRESS_HOST=$(kubectl get gateways.gateway.networking.k8s.io test-gw --namespace istio-ingress -ojsonpath='{.status.addresses[0].value}')
echo $INGRESS_HOST
kubectl get gatewayclass istio -o yaml -n istio-ingress




kubectl apply -f deployment.yaml --namespace default
kubectl apply -f service.yaml --namespace default


# kubectl apply -f httproute.yaml

# kubectl get pods
# kubectl get service

#curl -s -I -HHost:www.example.com "http://$INGRESS_HOST:8080"
