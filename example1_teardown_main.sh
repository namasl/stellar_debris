#!/bin/bash
# Tear down environment from running example1_v0.7.0.sh

if [ -z $1 ]; then
  echo "$0: missing directory to execute example in"
  echo "Usage: $0 DIRECTORY"
  exit 1
fi

WORKING_DIR=$1

cd $WORKING_DIR
# ensure WORKING_DIR is an absolute path
WORKING_DIR=$(pwd)

export KUBECONFIG="$WORKING_DIR/.kcp/admin.kubeconfig"

GUILDER_WS=$(kubectl get Workspace -o json | jq -r '.items | .[] | .metadata | select(.annotations ["edge.kubestellar.io/sync-target-name"] == "guilder") | .name')
FLORIN_WS=$(kubectl get Workspace -o json | jq -r '.items | .[] | .metadata | select(.annotations ["edge.kubestellar.io/sync-target-name"] == "florin") | .name')

kubectl ws root
kubectl delete workspace imw-1
kubectl delete workspace $FLORIN_WS
kubectl delete workspace $GUILDER_WS
kubectl kubestellar remove wmw wmw-c
kubectl kubestellar remove wmw wmw-s
kind delete cluster --name florin
kind delete cluster --name guilder
kubestellar stop

echo "*** Remove files"
rm -rf $WORKING_DIR/.kcp
rm -rf $WORKING_DIR/.kube/
rm -rf $WORKING_DIR/*.yaml

echo "*** End screen sessions"
screen -S kcp -p 0 -X stuff "exit^M"
screen -S mbx -p 0 -X stuff "exit^M"
screen -S pt -p 0 -X stuff "exit^M"
screen -S wr -p 0 -X stuff "exit^M"
