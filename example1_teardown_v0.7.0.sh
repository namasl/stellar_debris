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

export $WORKING_DIR/.kcp/admin.kubeconfig

kubectl ws root
kubectl delete workspace example-imw
kubectl ws root:my-org
kubectl kubestellar remove wmw example-wmw
kubectl ws root
kubectl delete workspace my-org
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
