#!/bin/bash

HN="debian"

if [ -z $1 ]; then
  echo "$0: missing directory to execute example in"
  echo "Usage: $0 DIRECTORY"
  exit 1
fi

WORKING_DIR=$1

cd $WORKING_DIR
# ensure WORKING_DIR is an absolute path
WORKING_DIR=$(pwd)

echo "------------------------------------------------------------------------"
echo "Running example in directory $WORKING_DIR"
echo ""
echo "KCP version: $(kcp --version)"
echo "KCP location: $(which kcp)"
echo ""
echo "KubeStellar version: $(kubestellar-version)"
echo "KubeStellar location: $(which kubestellar)"
echo ""
echo "------------------------------------------------------------------------"

# Pre-req

echo "*** Make kind for ks-core"

KUBECONFIG=$WORKING_DIR/.kube/config kind create cluster --name ks-core --config - <<EOF
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

echo "*** Create nginx ingress"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl \
  create -f https://raw.githubusercontent.com/kubestellar/kubestellar/main/example/kind-nginx-ingress-with-SSL-passthrough.yaml

echo "*** Wait 20 seconds"

sleep 20

echo "*** Wait for ingress"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

echo "*** Make kind ks-edge-cluster1"

KUBECONFIG=$WORKING_DIR/.kube/config kind create cluster --name ks-edge-cluster1 --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 8081
    hostPort: 8094
EOF

echo "*** Make kind ks-edge-cluster2"

KUBECONFIG=$WORKING_DIR/.kube/config kind create cluster --name ks-edge-cluster2 --config - <<EOF
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

echo "*** Rename kind clusters, removing 'kind-ks' prefix"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl config rename-context kind-ks-core ks-core
KUBECONFIG=$WORKING_DIR/.kube/config kubectl config rename-context kind-ks-edge-cluster1 ks-edge-cluster1
KUBECONFIG=$WORKING_DIR/.kube/config kubectl config rename-context kind-ks-edge-cluster2 ks-edge-cluster2

# 1. Deploy the KUBESTELLAR Core component

echo "*** Use context 'ks-core', create namespace 'kubestellar'"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl config use-context ks-core  
KUBECONFIG=$WORKING_DIR/.kube/config kubectl create namespace kubestellar  

echo "*** Install Kubestellar core with Helm"

helm repo add kubestellar https://helm.kubestellar.io
helm repo update
KUBECONFIG=$WORKING_DIR/.kube/config helm install kubestellar/kubestellar-core \
  --set EXTERNAL_HOSTNAME="$HN" \
  --set EXTERNAL_PORT=1119 \
  --namespace kubestellar \
  --generate-name

echo -n 'Waiting for KubeStellar to be ready'
while ! KUBECONFIG=$WORKING_DIR/.kube/config kubectl exec $(KUBECONFIG=$WORKING_DIR/.kube/config kubectl get pod \
   --selector=app=kubestellar -o jsonpath='{.items[0].metadata.name}' -n kubestellar) \
   -n kubestellar -c init -- ls /home/kubestellar/ready &> /dev/null; do
   sleep 10
   echo -n "."
done

echo; echo; echo "KubeStellar is now ready to take requests"

# 2. Install KUBESTELLAR's user commands and kubectl plugins
# skip all the brew commands

# 3. View your KUBESTELLAR Core Space environment

echo "*** Get secrets, dump to 'ks-core.kubeconfig'"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-core get secrets kubestellar \
  -o jsonpath='{.data.external\.kubeconfig}' \
  -n kubestellar | base64 -d > $WORKING_DIR/ks-core.kubeconfig

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl ws --context root tree

# 4. Install KUBESTELLAR Syncers on your Edge Clusters

echo "*** Prepare syncers for ks-edge-cluster1 and ks-edge-cluster2"

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl kubestellar prep-for-cluster --imw root:imw1 ks-edge-cluster1 \
  env=ks-edge-cluster1 \
  location-group=edge     #add ks-edge-cluster1 and ks-edge-cluster2 to the same group

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl kubestellar prep-for-cluster --imw root:imw1 ks-edge-cluster2 \
  env=ks-edge-cluster2 \
  location-group=edge     #add ks-edge-cluster1 and ks-edge-cluster2 to the same group

echo "*** Apply syncer to ks-edge-cluster1"

#apply ks-edge-cluster1 syncer
KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster1 apply -f ks-edge-cluster1-syncer.yaml
sleep 3
echo "*** Check if syncer deployed to ks-edge-cluster1"
KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster1 get pods -A | grep kubestellar  #check if syncer deployed to ks-edge-cluster1 correctly

echo "*** Apply syncer to ks-edge-cluster2"

#apply ks-edge-cluster2 syncer
KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster2 apply -f ks-edge-cluster2-syncer.yaml
sleep 3
echo "*** Check if syncer deployed to ks-edge-cluster2"
KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster2 get pods -A | grep kubestellar  #check if syncer deployed to ks-edge-cluster2 correctly

# 5. Deploy an Apache Web Server to ks-edge-cluster1 and ks-edge-cluster2

echo "*** Create EdgePLacement"

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl ws root:wmw1

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl apply -f - <<EOF
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

echo "*** Check if EdgePlacement applied to ks-core"

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl ws root:wmw1
KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl get edgeplacements -n kubestellar -o yaml

echo "*** Apply workload to WDS on ks-core (wmw1)"

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl apply -f - <<EOF
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

echo "*** Check if ConfigMap and Deployment applied to ks-core in 'my-namespace'"

KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl ws root:wmw1
KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl get deployments/my-first-kubestellar-deployment -n my-namespace -o yaml
KUBECONFIG=$WORKING_DIR/ks-core.kubeconfig kubectl get deployments,cm -n my-namespace

# 6. View the Apache Web Server running on ks-edge-cluster1 and ks-edge-cluster2

echo "*** Check that deployment was created on ks-edge-cluster1"
KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster1 get deployments -A

echo "*** Check that deployment was created on ks-edge-cluster2"
KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster2 get deployments -A

echo "*** Check that workload is running on  ks-edge-cluster1"
while [[ $(KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster1 get pod \
  -l "app=common" -n my-namespace -o jsonpath='{.items[0].status.phase}') != "Running" ]]; do 
    sleep 5; 
  done;
curl http://localhost:8094

echo "*** Check that workload is running on  ks-edge-cluster2"
while [[ $(KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context ks-edge-cluster2 get pod \
  -l "app=common" -n my-namespace -o jsonpath='{.items[0].status.phase}') != "Running" ]]; do 
    sleep 5; 
  done;
curl http://localhost:8096
