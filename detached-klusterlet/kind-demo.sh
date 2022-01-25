#!/usr/bin/env bash

DEMO_DIR="$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd ${DEMO_DIR}/.. && pwd)"
echo "DEMO_DIR: ${DEMO_DIR}, ROOT_DIR: ${ROOT_DIR}"

########################
# include the magic
########################
. demo-magic.sh
. common.sh

########################
# Configure the options
########################

#
# speed at which to simulate typing. bigger num = faster
#
# TYPE_SPEED=20

#
# custom prompt
#
# see http://www.tldp.org/HOWTO/Bash-Prompt-HOWTO/bash-prompt-escape-sequences.html for escape sequences
#
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W "

# text color
# DEMO_CMD_COLOR=$BLACK

# hide the evidence
clear

# Predefine some variables
operator_dir="/home/go/src/open-cluster-management.io/registration-operator"

export KUBECONFIG=$HOME/.kube/config
kind_hub_cluster="hub"
kind_management_cluster="management"
kind_managed_cluster="spoke"


export KLUSTERLET_NAME="klusterlet-2"
# KLUSTERLET_MANAGED_CLUSTER_NAME is the name of "clusterName" field in the Klusterlet CR.
export KLUSTERLET_MANAGED_CLUSTER_NAME="cluster2"

klusterlet_cr_path="${DEMO_DIR}/klusterlet-template.yaml"
manifestwork_cr_path="${DEMO_DIR}/manifestwork-template.yaml"

hub_kubeconfig_path=$operator_dir/.hub-kubeconfig
managed_kubeconfig_path=$operator_dir/.external-managed-kubeconfig
# Complete the variables defination


# Put your stuff here
function switchContext(){
    local context=$1
    commentNoWait "kubectl config use-context ${context}"
    kubectl config use-context ${context}

}
function checkPrerequisites(){
    pei "kind get clusters"
}

function installHub(){
    comment "Start to install components on the ACM hub cluster..."
    pushd $operator_dir || (echo "Please check the registration operator path: $operator_dir" && return)

    switchContext kind-${kind_hub_cluster}
    pei "make deploy-hub"
    pe "kubectl get pod -n open-cluster-management"
    pei "kubectl get pod -n open-cluster-management-hub"
    # kubectl get deployment -n open-cluster-management-hub cluster-manager-registration-controller
    waitFor deployment cluster-manager-registration-controller open-cluster-management-hub
    popd || return
}

function installKlusterletOperator(){
    comment "Start to install klusterlet operator and CRD on the management cluster..."
    pushd $operator_dir || (echo "Please check the registration operator path: $operator_dir" && return)

    switchContext kind-${kind_management_cluster}
    pei "make deploy-spoke-operator"
    pe "kubectl get pod -n open-cluster-management"
    # kubectl get deployment -n open-cluster-management klusterlet
    waitFor deployment klusterlet open-cluster-management
    popd || return
}

function applyKlusterletCR(){
    comment "Start to create a detached mode klusterlet CR"

    switchContext kind-${kind_management_cluster}
    pei "envsubst < $klusterlet_cr_path | kubectl apply -f -"
    pei "envsubst < $klusterlet_cr_path"
    wait

    kind get kubeconfig --name=${kind_hub_cluster} --internal > $hub_kubeconfig_path
    waitFor namespace ${KLUSTERLET_NAME}
    kubectl create secret generic bootstrap-hub-kubeconfig --from-file=kubeconfig=$hub_kubeconfig_path -n ${KLUSTERLET_NAME}
}

function createExternalManagedClusterKubeconfig(){
    comment "Start to create the external-managed-kubeconfig secret under the <klusterlet-name> namespace"
    switchContext kind-${kind_management_cluster}
    kind get kubeconfig --name=${kind_managed_cluster} --internal > $managed_kubeconfig_path
    waitFor namespace ${KLUSTERLET_NAME}
    pei "kubectl create secret generic external-managed-kubeconfig --from-file=kubeconfig=$managed_kubeconfig_path -n ${KLUSTERLET_NAME}"
    waitFor deployment ${KLUSTERLET_NAME}-registration-agent ${KLUSTERLET_NAME}
}

function approveManagedClusterJoin(){
    comment "Start to approve managed cluster on the hub cluster"

    switchContext kind-${kind_hub_cluster}
    pei "kubectl get managedcluster"
    waitFor managedcluster ${KLUSTERLET_MANAGED_CLUSTER_NAME}
    pei "kubectl patch managedcluster ${KLUSTERLET_MANAGED_CLUSTER_NAME} -p='{\"spec\":{\"hubAcceptsClient\":true}}' --type=merge"
    pei "kubectl get csr -l open-cluster-management.io/cluster-name=${KLUSTERLET_MANAGED_CLUSTER_NAME} | grep -v NAME | awk '{print \$1}' | xargs kubectl certificate approve"
    pei "kubectl get managedcluster"
    switchContext kind-${kind_management_cluster}
    pei "kubectl get pod -n ${KLUSTERLET_NAME}"
}

function createManifestWork(){
    comment "Start to create and check manifest work"
    switchContext kind-${kind_hub_cluster}
    pei "envsubst < $manifestwork_cr_path | kubectl apply -f -"
    pei "envsubst < $manifestwork_cr_path"
    wait

    switchContext kind-${kind_managed_cluster}
    pei "kubectl get appliedmanifestworks"
    waitFor deployment hello default
    pei "kubectl get pod -n default"
}

function _usage() {
    echo -e ""
    echo -e "Usage: $0 [options]"
    echo -e "\t$0 help you import a managed cluster by running klusterlet outside of the cluster"
    echo -e ""
    echo -e "\t-a\tdemonstrate all things"

    echo -e "\t-h\tinstall the cluster manager ont the hub cluster"
    echo -e "\t-k\tintall the klusterlet operator on the management cluster"
    echo -e "\t-c\tcreate a detached mode klusterlet CR"
    echo -e "\t-s\tcreate the external managed kubeconfig secret for the klusterlet"
    echo -e "\t-j\tacm hub approve the managed cluster joining"
    echo -e "\t-w\tcreate and check manifest work"
    echo -e ""
    echo -e "Note: this script will use kind, please prepare three kind cluster.\n      related issue: https://github.com/stolostron/backlog/issues/18359 "
}


while getopts ":acsjwkh" opt; do
    case "${opt}" in
    a)
        checkPrerequisites
        installHub
        installKlusterletOperator
        applyKlusterletCR
        createExternalManagedClusterKubeconfig
        approveManagedClusterJoin
        createManifestWork
        exit $?
        ;;
    c)
        applyKlusterletCR
        exit $?
        ;;
    s)
        createExternalManagedClusterKubeconfig
        exit $?
        ;;
    j)
        approveManagedClusterJoin
        exit $?
        ;;
    w)
        createManifestWork
        exit $?
        ;;
    k)
        installKlusterletOperator
        exit $?
        ;;
    h | ?)
        # _usage
        checkPrerequisites
        installHub
        exit 0
        ;;
    esac
done

_usage