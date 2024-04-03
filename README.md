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
```

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
```

Create a new GKE K8 Gateway:
```
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: gke-gateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
```
Create a Istio Gateway pointing to the istio gateway service by using the hostname:
```
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: istio-gateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  gatewayClassName: istio
  addresses:
  - value: asm-ingressgateway.${INGRESS_NAMESPACE}.svc.cluster.local
    type: Hostname
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
```
Create a HTTPROUTE to bind the 2 gateways:

```
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: asm-ingressgateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  parentRefs:
  - kind: Gateway
    name: gke-gateway
    namespace: ${INGRESS_NAMESPACE}
  rules:
  - backendRefs:
    - kind: Service
      name: asm-ingressgateway
      port: 80
```
Bind the deployment to the istio gateway Gateway via the HTTPRoute:
```
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: frontend
  namespace: onlineboutique
spec:
  parentRefs:
  - kind: Gateway
    name: istio-gateway
    namespace: ${INGRESS_NAMESPACE}
  rules:
  - backendRefs:
    - kind: Service
      name: frontend
      port: 80
```
Finally, test the new gateway:
```
INGRESS_IP=$(kubectl get gtw gke-gateway \
    -n ${INGRESS_NAMESPACE} \
    -o=jsonpath="{.status.addresses[0].value}")

echo -e "http://${INGRESS_IP}"
```

## Securing the gateway:

`DNS="frontend-onlineboutique.endpoints.${PROJECT_ID}.cloud.goog"`

```
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "${DNS}"
x-google-endpoints:
- name: "${DNS}"
  target: "${INGRESS_IP}"
```

Deploy it using gcloud:

`gcloud endpoints services deploy dns-spec.yaml`

Add Certs for the DNS:
```
openssl genrsa -out ${DNS}.key 2048
openssl req -x509 \
    -new \
    -nodes \
    -days 365 \
    -key ${DNS}.key \
    -out ${DNS}.crt \
    -subj "/CN=${DNS}"
```
Create a Secret with the TLS Cert:

```
kubectl create secret tls frontend-onlineboutique \
    -n asm-gateway \
    --key=${DNS}.key \
    --cert=${DNS}.crt
```

Update the Gateway to use the TLS Cert:

```
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: gke-gateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: frontend-onlineboutique
```
Update our deployment HTTPROUTE:
```
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: frontend
  namespace: onlineboutique
spec:
  parentRefs:
  - kind: Gateway
    name: istio-gateway
    namespace: ${INGRESS_NAMESPACE}
  hostnames:
  - "${DNS}"
  rules:
  - backendRefs:
    - name: frontend
      port: 80
```

Create a dedicated HealthCheckPolicy to target the actual Istio ingress gateway proxy’s port on 15021 instead of 443:

```
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: asm-ingressgateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  default:
    config:
      httpHealthCheck:
        port: 15021
        requestPath: /healthz/ready
      type: HTTP
  targetRef:
    group: ""
    kind: Service
    name: asm-ingressgateway
```

Finally, `echo -e "https://${DNS}"`

## Protect GKE behind Cloud Armor (WAF and DDOS protection)

Create and configure a Cloud Armor policy with a WAF rule and DDOS protection:

```
gcloud compute security-policies create gke-gateway-security-policy

gcloud compute security-policies update gke-gateway-security-policy \
    --enable-layer7-ddos-defense

gcloud compute security-policies rules create 1000 \
    --security-policy gke-gateway-security-policy \
    --expression "evaluatePreconfiguredExpr('xss-v33-stable')" \
    --action "deny-403" \
    --description "XSS attack filtering"
```

Assign this security poicy to the GKE Gateway:

```
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: asm-ingressgateway
  namespace: ${INGRESS_NAMESPACE}
spec:
  default:
    securityPolicy: gke-dev-security-policy
  targetRef:
    group: ""
    kind: Service
    name: asm-ingressgateway
```

You just secured the deployment behind the new Kubernetes Gateway API via an HTTPS endpoint and Cloud Armor with a WAF and a DDOS protection.

## More info
* [HTTP to HTTPS redirect](https://cloud.google.com/load-balancing/docs/https/setting-up-http-https-redirect)
* [Configure SSL Policies to secure client-to-load-balancer traffic](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources#configure_ssl_policies)
* [Secure load balancer to application traffic using SSL or TLS version](https://medium.com/@mabenoit/the-new-kubernetes-gateway-api-with-istio-and-anthos-service-mesh-asm-9d64c7009cd#:~:text=HTTP%20to%20HTTPS,or%20TLS%20version)
