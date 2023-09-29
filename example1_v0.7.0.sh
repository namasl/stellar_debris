#!/bin/bash
# This script primarily follows the extended example at
# https://docs.kubestellar.io/release-0.7/Coding%20Milestones/PoC2023q1/example1/

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

################################################################################
# Stage 1 of example
################################################################################

echo "*** Make kind clusters florin and guilder"

cat > florin-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 8081
    hostPort: 8094
EOF

KUBECONFIG=$WORKING_DIR/.kube/config kind create cluster --name florin --config florin-config.yaml

cat > guilder-config.yaml << EOF
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

KUBECONFIG=$WORKING_DIR/.kube/config kind create cluster --name guilder --config guilder-config.yaml

echo "************************************************************************"
echo '*** Start KCP in screen session "kcp"'
echo "************************************************************************"
export KUBECONFIG=$WORKING_DIR/.kcp/admin.kubeconfig
screen -d -m -S kcp
screen -S kcp -p 0 -X stuff "kcp start^M"
echo "*** Wait 30 seconds, starting at $(date)"
sleep 30

echo "*** Initialize KubeStellar as a bare process"
kubestellar init

echo "*** Make inventory management workspace"
kubectl ws root
kubectl ws create imw-1 

echo "*** Add labels to florin and guilder"
kubectl ws root:imw-1
kubectl kubestellar ensure location florin  loc-name=florin  env=prod
kubectl kubestellar ensure location guilder loc-name=guilder env=prod extended=si

echo "*** Show florin location object description"
kubectl describe location.edge.kubestellar.io florin

echo "************************************************************************"
echo '*** Make mailbox-controller in screen session "mbx"'
echo "************************************************************************"
screen -d -m -S mbx
screen -S mbx -p 0 -X stuff "kubectl ws root:espw; mailbox-controller -v=2^M"
echo "*** Wait 60 seconds, starting at $(date)"
sleep 60

echo "*** Show mailbox workspaces"
kubectl ws root:espw
kubectl get Workspaces

kubectl get Workspace -o "custom-columns=NAME:.metadata.name,SYNCTARGET:.metadata.annotations['edge\.kubestellar\.io/sync-target-name'],CLUSTER:.spec.cluster"

# asign workspace names to variables

GUILDER_WS=$(kubectl get Workspace -o json | jq -r '.items | .[] | .metadata | select(.annotations ["edge.kubestellar.io/sync-target-name"] == "guilder") | .name')

FLORIN_WS=$(kubectl get Workspace -o json | jq -r '.items | .[] | .metadata | select(.annotations ["edge.kubestellar.io/sync-target-name"] == "florin") | .name')

echo "* The guilder mailbox workspace name is $GUILDER_WS"
echo "* The florin mailbox workspace name is $FLORIN_WS"

echo "*** Connect guilder and florin edge clusters to their mailbox workspace"

kubectl kubestellar prep-for-syncer --imw root:imw-1 guilder

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-guilder apply -f guilder-syncer.yaml

kubectl kubestellar prep-for-syncer --imw root:imw-1 florin

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-florin apply -f florin-syncer.yaml 

echo "*** Show that syncer is running in kind-guilder context"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-guilder get deploy -A

################################################################################
# Stage 2 of example
################################################################################

echo "*** Make parent workspace my-org for common and special WMW"
kubectl ws root
kubectl ws create my-org --enter

echo "*** Make common WMW wmw-c"
kubectl kubestellar ensure wmw wmw-c

echo "*** Make workload objects in wmw-c workspace"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: commonstuff
  labels: {common: "si"}
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: commonstuff
  name: httpd-htdocs
  annotations:
    edge.kubestellar.io/expand-parameters: "true"
data:
  index.html: |
    <!DOCTYPE html>
    <html>
      <body>
        This is a common web site.
        Running in %(loc-name).
      </body>
    </html>
---
apiVersion: edge.kubestellar.io/v1alpha1
kind: Customizer
metadata:
  namespace: commonstuff
  name: example-customizer
  annotations:
    edge.kubestellar.io/expand-parameters: "true"
replacements:
- path: "$.spec.template.spec.containers.0.env.0.value"
  value: '"env is %(env)"'
---
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  namespace: commonstuff
  name: commond
  annotations:
    edge.kubestellar.io/customizer: example-customizer
spec:
  selector: {matchLabels: {app: common} }
  template:
    metadata:
      labels: {app: common}
    spec:
      containers:
      - name: httpd
        env:
        - name: EXAMPLE_VAR
          value: example value
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

echo "*** Make EdgePlacement object"

kubectl apply -f - <<EOF
apiVersion: edge.kubestellar.io/v1alpha1
kind: EdgePlacement
metadata:
  name: edge-placement-c
spec:
  locationSelectors:
  - matchLabels: {"env":"prod"}
  namespaceSelector:
    matchLabels: {"common":"si"}
  nonNamespacedObjects:
  - apiGroup: apis.kcp.io
    resources: [ "apibindings" ]
    resourceNames: [ "bind-kubernetes", "bind-apps" ]
  upsync:
  - apiGroup: "group1.test"
    resources: ["sprockets", "flanges"]
    namespaces: ["orbital"]
    names: ["george", "cosmo"]
  - apiGroup: "group2.test"
    resources: ["cogs"]
    names: ["william"]
EOF

echo "*** Make special WMW wmw-w"

kubectl ws root:my-org
kubectl kubestellar ensure wmw wmw-s

echo "*** Make workload objects in wmw-s workspace"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: specialstuff
  labels: {special: "si"}
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: specialstuff
  name: httpd-htdocs
  annotations:
    edge.kubestellar.io/expand-parameters: "true"
data:
  index.html: |
    <!DOCTYPE html>
    <html>
      <body>
        This is a special web site.
        Running in %(loc-name).
      </body>
    </html>
---
apiVersion: edge.kubestellar.io/v1alpha1
kind: Customizer
metadata:
  namespace: specialstuff
  name: example-customizer
  annotations:
    edge.kubestellar.io/expand-parameters: "true"
replacements:
- path: "$.spec.template.spec.containers.0.env.0.value"
  value: '"in %(env) env"'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: specialstuff
  name: speciald
  annotations:
    edge.kubestellar.io/customizer: example-customizer
spec:
  selector: {matchLabels: {app: special} }
  template:
    metadata:
      labels: {app: special}
    spec:
      containers:
      - name: httpd
        env:
        - name: EXAMPLE_VAR
          value: example value
        image: library/httpd:2.4
        ports:
        - name: http
          containerPort: 80
          hostPort: 8082
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

echo "*** Make EdgePlacement object"

kubectl apply -f - <<EOF
apiVersion: edge.kubestellar.io/v1alpha1
kind: EdgePlacement
metadata:
  name: edge-placement-s
spec:
  locationSelectors:
  - matchLabels: {"env":"prod","extended":"si"}
  namespaceSelector: 
    matchLabels: {"special":"si"}
  nonNamespacedObjects:
  - apiGroup: apis.kcp.io
    resources: [ "apibindings" ]
    resourceNames: [ "bind-kubernetes" ]
  upsync:
  - apiGroup: "group1.test"
    resources: ["sprockets", "flanges"]
    namespaces: ["orbital"]
    names: ["george", "cosmo"]
  - apiGroup: "group3.test"
    resources: ["widgets"]
    names: ["*"]
EOF


echo "************************************************************************"
echo 'Make where-resolver in screen session "wr"'
echo "************************************************************************"
export KUBECONFIG=$WORKING_DIR/.kcp/admin.kubeconfig
screen -d -m -S wr
screen -S wr -p 0 -X stuff "kubectl ws root:espw; kubestellar-where-resolver^M"
echo "*** Wait 45 seconds, starting at $(date)"
sleep 45

echo "*** Look at SinglePLacementSlice objects in wmw-c"
kubectl ws root:my-org:wmw-c
kubectl get SinglePlacementSlice -o yaml

################################################################################
# Stage 3 of example
################################################################################

echo "************************************************************************"
echo 'Make placement-translator in screen session "pt"'
echo "************************************************************************"
export KUBECONFIG=$WORKING_DIR/.kcp/admin.kubeconfig
screen -d -m -S pt
screen -S pt -p 0 -X stuff "kubectl ws root:espw; placement-translator^M"
echo "*** Wait 120 seconds, starting at $(date)"
sleep 120

echo "*** Examine florin's SyncerConfig"
kubectl ws root:espw
kubectl ws $FLORIN_WS
kubectl get SyncerConfig the-one -o yaml

echo "*** Check florin namespaces and replicasets for workload"
kubectl get ns
kubectl get replicasets -A

echo "*** Examine guilder's SyncerConfig"
kubectl ws root:espw
kubectl ws $GUILDER_WS
kubectl get SyncerConfig the-one -o yaml

echo "*** Check guilder namespaces and replicasets for workload"
kubectl get ns
kubectl get deployments,replicasets -A

################################################################################
# Stage 4 of example
################################################################################

echo "*** Examine florin cluster"

( KUBECONFIG=$WORKING_DIR/.kube/config
  let tries=1
  while ! kubectl --context kind-florin get ns commonstuff &> /dev/null; do
    if (( tries >= 30)); then
      echo "The commonstuff namespace failed to appear in florin!" >&2
      exit 10
    fi
    let tries=tries+1
    sleep 10
  done
  kubectl --context kind-florin get ns
)

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-florin get deploy,rs -A | egrep 'NAME|stuff'

echo "*** Examine guilder cluster"

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-guilder get ns | egrep NAME\|stuff

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-guilder get deploy,rs -A | egrep NAME\|stuff

KUBECONFIG=$WORKING_DIR/.kube/config kubectl --context kind-guilder get rs -n commonstuff commond -o yaml

echo "*** Check common workload on florin cluster"

let tries=1
while ! curl http://localhost:8094 &> /dev/null; do
  if (( tries >= 30 )); then
    echo "The common workload failed to come up on florin!" >&2
    exit 10
  fi
  let tries=tries+1
  sleep 10
done
curl http://localhost:8094

echo "*** Check special workload on guilder cluster"

let tries=1
while ! curl http://localhost:8097 &> /dev/null; do
  if (( tries >= 30 )); then
    echo "The special workload failed to come up on guilder!" >&2
    exit 10
  fi
  let tries=tries+1
  sleep 10
done
curl http://localhost:8097

echo "*** Check common workload on guilder cluster"

let tries=1
while ! curl http://localhost:8096 &> /dev/null; do
  if (( tries >= 30 )); then
    echo "The common workload failed to come up on guilder!" >&2
    exit 10
  fi
  let tries=tries+1
  sleep 10
done
curl http://localhost:8096

echo "*** DONE"
