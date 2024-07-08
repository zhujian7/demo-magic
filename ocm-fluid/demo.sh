#!/usr/bin/env bash


TMP_DEMO_DIR="$(dirname "${BASH_SOURCE[0]}")"
DEMO_DIR="$(cd ${TMP_DEMO_DIR} && pwd)"
ROOT_DIR="$(cd ${DEMO_DIR}/.. && pwd)"

echo "DEMO_DIR: ${DEMO_DIR}, ROOT_DIR: ${ROOT_DIR}"

########################
# include the magic
########################
. ${ROOT_DIR}/demo-magic.sh
. ${ROOT_DIR}/common.sh

########################
# Configure the options
########################

#
# speed at which to simulate typing. bigger num = faster
#
TYPE_SPEED=80

#
# custom prompt
#
# see http://www.tldp.org/HOWTO/Bash-Prompt-HOWTO/bash-prompt-escape-sequences.html for escape sequences
#
# DEMO_PROMPT="${GREEN}➜ ${CYAN}\W# "
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W$ ${COLOR_RESET}"

# text color
# DEMO_CMD_COLOR=$BLACK

# hide the evidence
clear

#
# KUBECONFIG=$HOME/.kube/config
# export KUBECONFIG

source ${DEMO_DIR}/credentials/hub-url.txt

HUB_KUBECONFIG="${KUBECONFIG:=${DEMO_DIR}/credentials/ocm-hub.kubeconfig}"
GKE1_KUBECONFIG="${GKE1_KUBECONFIG:=${DEMO_DIR}/credentials/gke1.kubeconfig}"
# echo "HUB_KUBECONFIG: ${HUB_KUBECONFIG} GKE1_KUBECONFIG: ${GKE1_KUBECONFIG}"
# echo "HUB_API_SERVER: ${HUB_API_SERVER}"

PLACEMENT_NAME="placement-gpu"

function ensureClusteradmCli() {
    if ! command -v clusteradm &> /dev/null
    then
        echo "clusteradm could not be found"
    fi
}

function setUpEnvironment() {
    ensureClusteradmCli
    ${DEMO_DIR}/local-up.sh
}

function enableAppAddons() {
    comment "Install the application-manager addon"
    pei "clusteradm install hub-addon --names application-manager"

    clusters=$(getPlacementResults placement-all)
    echo "clusters: ${clusters}"
    for current_cluster in ${clusters}; do
        pei "clusteradm addon enable --names application-manager --clusters ${current_cluster}"
    done

    pei "kubectl get managedclusteraddon --all-namespaces"
}

function enableResourceUsageCollectAddons(){
    comment "Install the resource-usage-collect addon"
    pei "kubectl apply -f ${DEMO_DIR}/manifests/resource-usage-collect-addon"

    pei "kubectl get managedclusteraddon --all-namespaces"
}

function enableFluidAddons(){
    comment "Install the fluid addon"
    pei "kubectl apply -f ${DEMO_DIR}/manifests/fluid-addon"

    pei "kubectl get managedclusteraddon --all-namespaces"
}

function loadImages(){
    clusters=$(getPlacementResults placement-all)
    echo "clusters: ${clusters}"
    for current_cluster in ${clusters}; do
        pei "loadFluidImages ${current_cluster}"
    done
}

function loadFluidImages(){
    clusterName=$1
    if [ -z "$clusterName" ]; then
        echo "clusterName is required"
        exit 1
    fi
    kind load docker-image --name=${clusterName} fluidcloudnative/alluxioruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/dataset-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/efcruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/application-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/goosefsruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/jindoruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/juicefsruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/thinruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/vineyardruntime-controller:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/csi-node-driver-registrar:v2.3.0
    kind load docker-image --name=${clusterName} fluidcloudnative/fluid-csi:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/fluid-crd-upgrader:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} fluidcloudnative/fluid-webhook:v1.0.0-31f5433
    kind load docker-image --name=${clusterName} nginx
}

function createPlacements(){
    kubectl apply -f ${DEMO_DIR}/manifests/placements
    kubectl get placement
    kubectl wait --timeout=1m placement/placement-all --for=condition=PlacementSatisfied
    # kubectl wait --timeout=1m placement/placement-gpu --for=condition=PlacementSatisfied
    # kubectl wait --timeout=1m placement/placement-cpu --for=condition=PlacementSatisfied
}

function installNginx(){
    comment "Deploy the nginx application"
    pei "kubectl apply -f ${DEMO_DIR}/manifests/nginx-application"
}

function checkNginx(){
    comment "Check the nginx application"
    pei "kubectl get managedcluster"
    pei "kubectl get subscriptions.apps.open-cluster-management.io -n default"
}

function createGPUApp(){
    pei "kubectl wait --timeout=1m placement/${PLACEMENT_NAME} --for=condition=PlacementSatisfied"
    comment "Create a GPU application on the selected clusters"
    # pei "clusteradm create work my-gpu-app --placement default/${PLACEMENT_NAME} --replicaset=true --overwrite -f ${DEMO_DIR}/manifests/application/deployment.yaml"

    export PLACEMENT_NAME
    pei "envsubst < ${DEMO_DIR}/manifests/application/mwrs-gpu-app.yaml | kubectl apply -f -"
}

function createFluidDataset(){
    comment "Create a Fluid dataset"
    # check if the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables are set
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        echo "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables are required"
        exit 1
    fi

    pei "kubectl wait --timeout=1m placement/${PLACEMENT_NAME} --for=condition=PlacementSatisfied"

    # pei "envsubst < ${DEMO_DIR}/manifests/application/alluxio-dataset-s3.yaml | clusteradm create work my-model-dataset --placement default/${PLACEMENT_NAME} --replicaset=true --overwrite -f -"
    export PLACEMENT_NAME
    pei "envsubst < ${DEMO_DIR}/manifests/application/mwrs-dataset.yaml | kubectl apply -f -"
}

function createFluidDataLoad(){
    comment "Create a Fluid data load"
    pei "kubectl wait --timeout=1m placement/${PLACEMENT_NAME} --for=condition=PlacementSatisfied"
    # pei "clusteradm create work my-dataload --placement default/${PLACEMENT_NAME} --replicaset=true --overwrite -f ${DEMO_DIR}/manifests/application/dataload.yaml"

    export PLACEMENT_NAME
    pei "envsubst < ${DEMO_DIR}/manifests/application/mwrs-dataload.yaml | kubectl apply -f -"
}

function getPlacementResults(){
    placement_name=$1
    if [ -z "$placement_name" ]; then
        echo "placement_name is required"
        exit 1
    fi

    decision_name=$(kubectl get placement ${placement_name} -ojsonpath='{.status.decisionGroups[0].decisions[0]}')
    if [ -z "$decision_name" ]; then
        echo "decision_name is required"
        exit 1
    fi

    clusters=$(kubectl get placementdecision ${decision_name} -ojsonpath='{.status.decisions[*].clusterName}')
    if [ -z "$clusters" ]; then
        echo "clusters is required"
        exit 1
    fi

    echo "${clusters}"
}

function getAddonPlacementScores(){
    local clusters=$(kubectl get addonplacementscores -A | grep -v NAMESPACE | awk '{print $1}')

    for current_cluster in ${clusters}; do
        kubectl get addonplacementscores -n ${current_cluster} resource-usage-score\
         -o custom-columns=CLUSTER:.metadata.namespace,GPU_AVAILABLE_SCORE:'.status.scores[?(@.name=="gpuAvailable")].value'
    done
}

function saveHubCA(){
    kubectl get configmap kube-root-ca.crt -ojsonpath='{.data.ca\.crt}' > ${DEMO_DIR}/credentials/hub-ca.crt
    local hub_apiserver_url=$(kubectl get infrastructures.config.openshift.io cluster -ojsonpath={.status.apiServerURL})
    echo "HUB_API_SERVER=${hub_apiserver_url}" > ${DEMO_DIR}/credentials/hub-url.txt
}

function saveGKEcredentials(){
    export KUBECONFIG=${GKE1_KUBECONFIG}
    gcloud container clusters get-credentials zj-cluster-1 --zone us-central1-c --project gc-acm-dev
    export KUBECONFIG=${HUB_KUBECONFIG}
}

function hubInit(){
    clusteradm init --wait --feature-gates=ManifestWorkReplicaSet=true --bundle-version='latest'
}

function join(){
    local cluster_name=$1
    if [ -z "$cluster-name" ]; then
        echo "cluster-name is required"
        exit 1
    fi
    local managed_kubeconfig=$2
    if [ -z "$managed_kubeconfig" ]; then
        echo "managed_kubeconfig is required"
        exit 1
    fi

    echo "cluster_name: ${cluster_name}, managed_kubeconfig: ${managed_kubeconfig}"
    local token=$(clusteradm get token | awk -F'=' '/^token=/ {print substr($0, index($0,$2))}')

    export KUBECONFIG=${managed_kubeconfig}
    clusteradm join --hub-token ${token} \
    --hub-apiserver ${HUB_API_SERVER} \
    --ca-file=/home/go/src/github.com/zhujian7/demo-magic/ocm-fluid/credentials/hub-ca.crt \
    --bundle-version='latest' \
    --singleton \
    --wait --cluster-name ${cluster_name}

    export KUBECONFIG=${HUB_KUBECONFIG}
    kubectl get managedcluster
    # if cluster name contains "gke", label the managedcluster
    if [[ ${cluster_name} == *"gke"* ]]; then
        kubectl label managedcluster ${cluster_name} provider=gke
    fi
    # if cluster name is "local-cluster", lable the managedcluster
    if [[ ${cluster_name} == "local-cluster" ]]; then
        kubectl label managedcluster ${cluster_name} provider=ocp
    fi

    clusteradm accept --clusters ${cluster_name}
    kubectl get managedcluster
}

function addSCC(){
    oc apply -f- << EOF
    apiVersion: security.openshift.io/v1
    kind: SecurityContextConstraints
    metadata:
      name: fluid-scc
    allowHostDirVolumePlugin: true
    allowHostIPC: true
    allowHostNetwork: true
    allowHostPID: true
    allowHostPorts: true
    allowPrivilegeEscalation: true
    allowPrivilegedContainer: true
    allowedCapabilities:
      - "SYS_ADMIN"
    fsGroup:
      type: RunAsAny
    runAsUser:
      type: RunAsAny
    seLinuxContext:
      type: RunAsAny
    supplementalGroups:
      type: RunAsAny
    volumes:
      - "configMap"
      - "downwardAPI"
      - "emptyDir"
      - "hostPath"
      - "persistentVolumeClaim"
      - "projected"
      - "secret"
EOF

    oc adm policy add-scc-to-user fluid-scc -z fluid-csi -n fluid-system
    oc adm policy add-scc-to-user anyuid -z fluid-webhook -n fluid-system
}

# Function for the 'help' subcommand
help() {
  echo "Usage: $0 {setup-env|enable-addons|deploy-ai-app|deploy-app|all|call|help}"
  echo "setup-env     - Sep up the environment with 3 kind clusters"
  echo "enable-addons - Enable resource-usage-collect, fluid addons"
  echo "deploy-ai-app - Deploy an AI demo application with GPU and fluid dataset"
  echo "deploy-app    - Deploy an demo application"
  echo "all           - Run all the above commands in sequence"
  echo "call          - Call a specific function"
  echo "help          - Display this help message"
  echo "Note: If you are trying to use the fluid dataset, please make sure the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables are set."
}


# Check if at least one argument is provided
if [ $# -lt 1 ]; then
  echo "Error: No subcommand provided."
  help
  exit 1
fi

# Parse the first argument as the subcommand
case "$1" in
  setup-env)
    setUpEnvironment
    createPlacements
    loadImages
    ;;
  enable-addons)
    createPlacements > /dev/null 2>&1
    enableResourceUsageCollectAddons
    enableFluidAddons
    ;;
  deploy-app)
    createPlacements > /dev/null 2>&1
    enableAppAddons
    installNginx
    ;;
  deploy-ai-app)
    createPlacements > /dev/null 2>&1
    createFluidDataset
    createFluidDataLoad
    createGPUApp
    ;;
  all)
    setUpEnvironment
    createPlacements
    loadImages
    enableResourceUsageCollectAddons
    enableFluidAddons
    enableAppAddons
    installNginx
    createFluidDataset
    createFluidDataLoad
    createGPUApp
    ;;
  help)
    help
    ;;
  call)
    createPlacements > /dev/null 2>&1
    shift
    $@
    ;;
  *)
    echo "Error: Unknown subcommand '$1'."
    help
    exit 1
    ;;
esac

exit 0

# ########################################################################################
# Create a GKE cluster: 3 Nodes, each with "e2-standard-4   us-central1-c   4   16.00"
#                       1 Node, with NVIDIA T4 GPU
# 
# ########################################################################################

gcloud container clusters delete zj-cluster-1 --zone us-central1-c

gcloud container clusters create zj-cluster-1 \
    --zone us-central1-c \
    --machine-type=e2-standard-4 \
    --num-nodes=3

gcloud container node-pools create default-pool \
    --cluster=zj-cluster-1 \
    --zone us-central1-c \
    --machine-type=e2-standard-4 \
    --num-nodes=3

gcloud container node-pools delete gpu-pool \
    --cluster=zj-cluster-1 \
    --zone us-central1-c

gcloud container node-pools create gpu-pool \
    --cluster=zj-cluster-1 \
    --zone us-central1-c \
    --machine-type=n1-standard-2 \
    --num-nodes=1 \
    --accelerator type=nvidia-tesla-t4,count=1,gpu-driver-version=default
    # --accelerator type=nvidia-tesla-t4,count=1,gpu-driver-version=latest

