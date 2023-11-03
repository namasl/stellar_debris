HN="debian"

kind delete cluster --name ks-core
kind delete cluster --name ks-edge-cluster1
kind delete cluster --name ks-edge-cluster2

KUBECONFIG=~/.kube/config kubectl config delete-context ks-core || true
KUBECONFIG=~/.kube/config kubectl config delete-context ks-edge-cluster1 || true
KUBECONFIG=~/.kube/config kubectl config delete-context ks-edge-cluster2 || true

# Pre-req

KUBECONFIG=~/.kube/config kind create cluster --name ks-core --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 443
    hostPort: 1119
    protocol: TCP
EOF

KUBECONFIG=~/.kube/config kubectl \
  create -f https://raw.githubusercontent.com/kubestellar/kubestellar/main/example/kind-nginx-ingress-with-SSL-passthrough.yaml

sleep 10

KUBECONFIG=~/.kube/config kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

KUBECONFIG=~/.kube/config kind create cluster --name ks-edge-cluster1 --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 8081
    hostPort: 8094
EOF

KUBECONFIG=~/.kube/config kind create cluster --name ks-edge-cluster2 --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 8081
    hostPort: 8096
  - containerPort: 8082
    hostPort: 8097
EOF

KUBECONFIG=~/.kube/config kubectl config rename-context kind-ks-core ks-core
KUBECONFIG=~/.kube/config kubectl config rename-context kind-ks-edge-cluster1 ks-edge-cluster1
KUBECONFIG=~/.kube/config kubectl config rename-context kind-ks-edge-cluster2 ks-edge-cluster2

# 1. Deploy the KUBESTELLAR Core component

KUBECONFIG=~/.kube/config kubectl config use-context ks-core  
KUBECONFIG=~/.kube/config kubectl create namespace kubestellar  

helm repo add kubestellar https://helm.kubestellar.io
helm repo update
KUBECONFIG=~/.kube/config helm install kubestellar/kubestellar-core \
  --set EXTERNAL_HOSTNAME=$HN \
  --set EXTERNAL_PORT=1119 \
  --namespace kubestellar \
  --generate-name

echo -n 'Waiting for KubeStellar to be ready'
while ! KUBECONFIG=~/.kube/config kubectl exec $(KUBECONFIG=~/.kube/config kubectl get pod \
   --selector=app=kubestellar -o jsonpath='{.items[0].metadata.name}' -n kubestellar) \
   -n kubestellar -c init -- ls /home/kubestellar/ready &> /dev/null; do
   sleep 10
   echo -n "."
done

echo; echo; echo "KubeStellar is now ready to take requests"

KUBECONFIG=~/.kube/config kubectl --context ks-core get secrets kubestellar \
  -o jsonpath='{.data.external\.kubeconfig}' \
  -n kubestellar | base64 -d > ks-core.kubeconfig

KUBECONFIG=ks-core.kubeconfig kubectl ws --context root tree

# 2. Install KUBESTELLAR's user commands and kubectl plugins
# skip all the brew commands

# 3. View your KUBESTELLAR Core Space environment

KUBECONFIG=~/.kube/config kubectl --context ks-core get secrets kubestellar \
  -o jsonpath='{.data.external\.kubeconfig}' \
  -n kubestellar | base64 -d > ks-core.kubeconfig

KUBECONFIG=ks-core.kubeconfig kubectl ws --context root tree

# 4. Install KUBESTELLAR Syncers on your Edge Clusters

KUBECONFIG=ks-core.kubeconfig kubectl kubestellar prep-for-cluster --imw root:imw1 ks-edge-cluster1 \
  env=ks-edge-cluster1 \
  location-group=edge     #add ks-edge-cluster1 and ks-edge-cluster2 to the same group

KUBECONFIG=ks-core.kubeconfig kubectl kubestellar prep-for-cluster --imw root:imw1 ks-edge-cluster2 \
  env=ks-edge-cluster2 \
  location-group=edge     #add ks-edge-cluster1 and ks-edge-cluster2 to the same group

#apply ks-edge-cluster1 syncer
KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster1 apply -f ks-edge-cluster1-syncer.yaml
sleep 3
KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster1 get pods -A | grep kubestellar  #check if syncer deployed to ks-edge-cluster1 correctly

#apply ks-edge-cluster2 syncer
KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster2 apply -f ks-edge-cluster2-syncer.yaml
sleep 3
KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster2 get pods -A | grep kubestellar  #check if syncer deployed to ks-edge-cluster2 correctly

# 5. Deploy an Apache Web Server to ks-edge-cluster1 and ks-edge-cluster2

KUBECONFIG=ks-core.kubeconfig kubectl ws root:wmw1

KUBECONFIG=ks-core.kubeconfig kubectl apply -f - <<EOF
apiVersion: edge.kubestellar.io/v2alpha1
kind: EdgePlacement
metadata:
  name: my-first-edge-placement
spec:
  locationSelectors:
  - matchLabels: {"location-group":"edge"}
  downsync:
  - apiGroup: ""
    resources: [ configmaps ]
    namespaces: [ my-namespace ]
    objectNames: [ "*" ]
  - apiGroup: apps
    resources: [ deployments ]
    namespaces: [ my-namespace ]
    objectNames: [ my-first-kubestellar-deployment ]
  - apiGroup: apis.kcp.io
    resources: [ apibindings ]
    namespaceSelectors: []
    objectNames: [ "bind-kubernetes", "bind-apps" ]
EOF

KUBECONFIG=ks-core.kubeconfig kubectl ws root:wmw1
KUBECONFIG=ks-core.kubeconfig kubectl get edgeplacements -n kubestellar -o yaml

KUBECONFIG=ks-core.kubeconfig kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: my-namespace
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: my-namespace
  name: httpd-htdocs
data:
  index.html: |
    <!DOCTYPE html>
    <html>
      <body>
        This web site is hosted on ks-edge-cluster1 and ks-edge-cluster2.
      </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: my-namespace
  name: my-first-kubestellar-deployment
spec:
  selector: {matchLabels: {app: common} }
  template:
    metadata:
      labels: {app: common}
    spec:
      containers:
      - name: httpd
        image: library/httpd:2.4
        ports:
        - name: http
          containerPort: 80
          hostPort: 8081
          protocol: TCP
        volumeMounts:
        - name: htdocs
          readOnly: true
          mountPath: /usr/local/apache2/htdocs
      volumes:
      - name: htdocs
        configMap:
          name: httpd-htdocs
          optional: false
EOF

KUBECONFIG=ks-core.kubeconfig kubectl ws root:wmw1
KUBECONFIG=ks-core.kubeconfig kubectl get deployments/my-first-kubestellar-deployment -n my-namespace -o yaml
KUBECONFIG=ks-core.kubeconfig kubectl get deployments,cm -n my-namespace

# 6. View the Apache Web Server running on ks-edge-cluster1 and ks-edge-cluster2

KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster1 get deployments -A

KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster2 get deployments -A

while [[ $(KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster1 get pod \
  -l "app=common" -n my-namespace -o jsonpath='{.items[0].status.phase}') != "Running" ]]; do 
    sleep 5; 
  done;
curl http://localhost:8094

while [[ $(KUBECONFIG=~/.kube/config kubectl --context ks-edge-cluster2 get pod \
  -l "app=common" -n my-namespace -o jsonpath='{.items[0].status.phase}') != "Running" ]]; do 
    sleep 5; 
  done;
curl http://localhost:8096
