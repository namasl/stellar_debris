#!/bin/bash

if [ -z $1 ]; then
  echo "$0: missing directory to execute example in"
  echo "Usage: $0 DIRECTORY"
  exit 1
fi

WORKING_DIR=$1

cd $WORKING_DIR
# ensure WORKING_DIR is an absolute path
WORKING_DIR=$(pwd)

kind delete cluster --name ks-core
kind delete cluster --name ks-edge-cluster1
kind delete cluster --name ks-edge-cluster2

rm -rf $WORKING_DIR/.kube
rm $WORKING_DIR/ks-core.kubeconfig
rm $WORKING_DIR/ks-edge-cluster1-syncer.yaml
rm $WORKING_DIR/ks-edge-cluster2-syncer.yaml
