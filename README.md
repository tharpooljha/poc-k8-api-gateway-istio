# K8 Gateway API with istio and anthos
```
PROJECT_ID=FIXME-WITH-YOUR-PROJECT_ID
CLUSTER=cluster-with-gtw
ZONE=northamerica-northeast1-a

PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='get(projectNumber)')

gcloud services enable container.googleapis.com \
    gkehub.googleapis.com \
    anthos.googleapis.com \
    mesh.googleapis.com

gcloud container clusters create ${CLUSTER} \
    --zone ${ZONE} \
    --machine-type=e2-standard-4 \
    --workload-pool ${PROJECT_ID}.svc.id.goog \
    --gateway-api=standard \
    --labels mesh_id=proj-${PROJECT_NUMBER}

gcloud container fleet memberships register ${CLUSTER} \
    --gke-cluster ${ZONE}/${CLUSTER} \
    --enable-workload-identity

gcloud container fleet mesh enable

gcloud container fleet mesh update \
    --management automatic \
    --memberships ${CLUSTER}
```

* The only difference to notice is the use of the --gateway-api=standard parameter to install the GKE Gateway controller when creating the GKE cluster. If you create new Autopilot clusters on GKE 1.26 and later, Gateway API is enabled by default.

## Test the Gateway API
`kubectl get crd gateways.gateway.networking.k8s.io -o yaml | grep "gateway.networking.k8s.io/bundle-version"`

- This should return:
```
gke-l7-global-external-managed networking.gke.io/gateway
gke-l7-gxlb networking.gke.io/gateway
gke-l7-regional-external-managed networking.gke.io/gateway
gke-l7-rilb networking.gke.io/gateway
istio istio.io/gateway-controller
```

Let’s use the Google Service Mesh Cloud Gateway (asm-l7-gxlb)

Instead of using one of the gke-l7-* GatewayClasses , we will use the Google Service Mesh Cloud Gateway (asm-l7-gxlb). Its in GA as of time of writing.

```GatewayClass.yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: asm-l7-gxlb
spec:
  controllerName: mesh.cloud.google.com/gateway
```
Deploy K8 gateway erource attached to the gatewayClassName:
```Gateway.yaml
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: asm-gateway
  namespace: asm-gateway
spec:
  gatewayClassName: asm-l7-gxlb
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
```
- [The Gateway resource is created in the asm-gateway namespace. The GatewayClass is set to asm-l7-gxlb, which is the Google Service Mesh Cloud Gateway. The Gateway resource is configured to allow all routes from all namespaces.](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api#shared_gateway_per_cluster)

## Deploy a asm-gateway.
`kubectl get all -n asm-gateway`

- This should return:
```
NAME
pod/asm-gw-istio-asm-gateway-7f7795554-dgdmm

NAME                               TYPE
service/asm-gw-istio-asm-gateway   ClusterIP

NAME
deployment.apps/asm-gw-istio-asm-gateway

NAME
replicaset.apps/asm-gw-istio-asm-gateway-7f7795554
```