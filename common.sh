#!/usr/bin/env bash

# some scripts copy from ianzhang
function comment() {
    printf "$GREY# %s $GREEN\n" "$1"
    wait
}
function commentNoWait() {
    printf "$GREY# %s \n" "$1"
}

function waitFor() {
    local namespaceArgs=""
    local kubeconfigArgs=""
    local kind=$1
    local name=$2
    local ns=$3
    local kubeconfig=$4
    if [ -n "$ns" ];then
      namespaceArgs=" -n $ns"
    fi
    if [ -n "$kubeconfig" ];then
      kubeconfigArgs=" --kubeconfig $kubeconfig"
    fi

    echo "kubectl get $kind $name $namespaceArgs $kubeconfigArgs --no-headers --ignore-not-found=true"
    matched=$(kubectl get $kind $name $namespaceArgs $kubeconfigArgs --no-headers --ignore-not-found=true)

    while [ -z "$matched" ]; do
        matched=$(kubectl get $kind $name $namespaceArgs $kubeconfigArgs --no-headers --ignore-not-found=true)
        echo "Waiting for $kind ($ns/$name) to be created"
        sleep 3
    done
    # echo "$kind ($ns/$name) was created"
}

function switchKubeContext(){
    local context=$1
    commentNoWait "kubectl config use-context ${context}"
    kubectl config use-context ${context}
}
