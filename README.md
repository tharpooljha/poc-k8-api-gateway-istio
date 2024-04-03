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

Create a deployment for our gateway test:
```deployment.yaml
kubectl create namespace onlineboutique
kubectl label namespace onlineboutique istio-injection=enabled
helm upgrade onlineboutique oci://us-docker.pkg.dev/online-boutique-ci/charts/onlineboutique \
    --install \
    -n onlineboutique \
    --set frontend.externalService=false
```
Create a HTTPRoute for our new deployment.

HTTPRoute.yaml
```
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: frontend
  namespace: onlineboutique
spec:
  parentRefs:
  - kind: Gateway
    name: asm-gateway
    namespace: asm-gateway
  rules:
  - backendRefs:
    - name: frontend
      port: 80
Hit the public ip of the K8 Gateway

```terminal
INGRESS_IP=$(kubectl get gtw asm-gw-gke-asm-gateway \
    -n asm-gateway \
    -o=jsonpath="{.status.addresses[0].value}")

echo -e "http://${INGRESS_IP}"
```

## Clean up

The problem is that our default deployment doesn't have a seccompProfile or dedicated Service Account. No Role, RoleBinding, HPA, etc.

In order to do this, we will need to deploy a istio ingressgateway and service.

```asm-ingressgateway.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: asm-ingressgateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  selector:
    matchLabels:
      asm: ingressgateway
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway
      labels:
        asm: ingressgateway
    spec:
      containers:
      - name: istio-proxy
        image: auto
        env:
        - name: ISTIO_META_UNPRIVILEGED_POD
          value: "true"
        ports:
        - containerPort: 8080
          protocol: TCP
        resources:
          limits:
            cpu: 2000m
            memory: 1024Mi
          requests:
            cpu: 100m
            memory: 128Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - all
          privileged: false
          readOnlyRootFilesystem: true
      securityContext:
        fsGroup: 1337
        runAsGroup: 1337
        runAsNonRoot: true
        runAsUser: 1337
```
```service.yaml
apiVersion: v1
kind: Service
metadata:
  name: asm-ingressgateway
  namespace: ${INGRESS_NAMESPACE}
  labels:
    asm: ingressgateway
spec:
  ports:
  - name: http
    port: 80
    targetPort: 8080
  selector:
    asm: ingressgateway
  type: ClusterIP