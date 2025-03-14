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
TYPE_SPEED=200

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

source ${DEMO_DIR}/config/variable.txt

HUB_KUBECONFIG="${KUBECONFIG:=${DEMO_DIR}/credentials/ocm-hub.kubeconfig}"
KIND_KUBECONFIG="${DEMO_DIR}/manifests/credentials/kind.kubeconfig"
OIDC_PROVIDER_CA_PATH="${DEMO_DIR}/manifests/credentials/oidc_ca.crt"
CLIENT_TOKEN_PATH="${DEMO_DIR}/manifests/credentials/client_token"
echo "HUB_KUBECONFIG: ${HUB_KUBECONFIG}"
echo "KIND_KUBECONFIG: ${KIND_KUBECONFIG}"
echo "OIDC_PROVIDER_CA_PATH: ${OIDC_PROVIDER_CA_PATH}"

function init() {
    echo "Extract the app domain name, cluster hostname, and oidc provider address"
    export APP_DOMAIN=$(oc get cm -n openshift-config-managed console-public -o go-template="{{ .data.consoleURL }}" | sed 's@https://@@; s/^[^.]*\.//')
    echo "APP_DOMAIN: $APP_DOMAIN"

    export CLUSTER_HOSTNAME=$(echo "$APP_DOMAIN" | awk -F'.' '{print $2}')
    echo "CLUSTER_HOSTNAME: $CLUSTER_HOSTNAME"

    export OIDC_SERVER=oidc-discovery.$APP_DOMAIN
    echo "OIDC_SERVER: $OIDC_SERVER"

    export OIDC_PROVIDER_CA_PATH
}

function deploy_spiffe_on_ocp() {
    p "Create OCP SecurityContextConstraints(scc), and binding permissions for spire service account"
    pei "envsubst < ${DEMO_DIR}/manifests/spire-namespace.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-spire-scc.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-spire-scc-clusterrole.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-spire-scc-rolebinding-spire.yaml | kubectl apply -f -"

    deploy_spire_server_with_oidc_provider
    deploy_spiffe_agent
}

function deploy_spire_server_with_oidc_provider() {
    p "Deploy spire server and oidc provider"
    pei "envsubst < ${DEMO_DIR}/manifests/server/spire-bundle-configmap.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/server-account.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/server-cluster-role.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/server-configmap.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/oidc-configmap.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/server-service.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/oidc-service.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/server/server-statefulset.yaml | kubectl apply -f -"

    p "Expose the spire oidc provider via the OCP route"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-route-oidc-provider.yaml | kubectl apply -f -"
}

function deploy_spiffe_agent() {
    p "Deploy spire agent"
    envsubst <${DEMO_DIR}/manifests/spire-namespace.yaml | kubectl apply -f -
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-account.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-cluster-role.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-configmap.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-daemonset.yaml | kubectl apply -f -"
}

function register_workloads() {
    p "Register the node"
    pei "kubectl exec -n spire spire-server-0 -- \
        /opt/spire/bin/spire-server entry create \
        -spiffeID spiffe://$APP_DOMAIN/ns/spire/sa/spire-agent \
        -selector k8s_sat:cluster:hub \
        -selector k8s_sat:agent_ns:spire \
        -selector k8s_sat:agent_sa:spire-agent \
        -node"

    p "Register the workload"
    pei "kubectl exec -n spire spire-server-0 -- \
        /opt/spire/bin/spire-server entry create \
        -spiffeID spiffe://$APP_DOMAIN/ns/default/sa/default \
        -parentID spiffe://$APP_DOMAIN/ns/spire/sa/spire-agent \
        -selector k8s:ns:default \
        -selector k8s:sa:default"
}

function create_client() {
    p "Create a workload container to access spire"
    pei "envsubst < ${DEMO_DIR}/manifests/client/client-deployment.yaml | kubectl apply -f -"

    local client_pod=$(kubectl get pods -o=jsonpath='{.items[0].metadata.name}' -l app=client)
    kubectl wait --for=condition=Ready pod/${client_pod}
    pei "kubectl exec -it ${client_pod} -- /opt/spire/bin/spire-agent api fetch -socketPath /run/spire/sockets/agent.sock"
}

function prepare_oidc_ca() {
    p "Get the oidc provider ca by openssl s_client cli"

    openssl s_client -servername ${OIDC_SERVER} \
        -showcerts -connect ${OIDC_SERVER}:443 |
        awk '/BEGIN CERTIFICATE/{data=""; capture=1} capture {data=data $0 ORS} /END CERTIFICATE/{block=data; capture=0} END {print block}' \
            >${OIDC_PROVIDER_CA_PATH}
}

function create_kind_cluster() {
    pe "envsubst < ${DEMO_DIR}/manifests/kind/cluster-config.yaml | kind create cluster --name kind \
       --kubeconfig=${KIND_KUBECONFIG} --config -"
}

function get_client_token() {
    p "Get a client Token by spire-agent api fetch jwt"
    CLIENT_TOKEN=$(kubectl get pod -l app=client -o name | xargs -n 1 -I {} kubectl exec -it {} \
        -- /opt/spire/bin/spire-agent api fetch jwt -audience kube \
        -socketPath /run/spire/sockets/agent.sock | awk '/token\(/ {getline; print $1}')
    echo "${CLIENT_TOKEN}" >${CLIENT_TOKEN_PATH}
    export CLIENT_TOKEN
    echo "Token created"
}

function set_spiffe_kubeconfig() {
    if [ -z "${!CLIENT_TOKEN}" ]; then
        if [ -f "$CLIENT_TOKEN_PATH" ]; then
            export "CLIENT_TOKEN"=$(cat "$CLIENT_TOKEN_PATH")
            echo "set CLIENT_TOKEN from ${CLIENT_TOKEN_PATH}"
        else
            echo "File $CLIENT_TOKEN_PATH not found!"
        fi
    fi

    p "Grant permissions for the spiffe client"
    pei "envsubst <${DEMO_DIR}/manifests/kind/spire-user-binding.yaml | kubectl --kubeconfig=${KIND_KUBECONFIG} --context kind-kind apply -f -"

    p "Construct a kubeconfig using the client token"
    echo "kubectl --kubeconfig=${KIND_KUBECONFIG} --context kind-kind config set-credentials oidc-user --token=CLIENT_TOKEN"
    kubectl --kubeconfig=${KIND_KUBECONFIG} --context kind-kind config set-credentials oidc-user --token=${CLIENT_TOKEN}
    pei "kubectl --kubeconfig=${KIND_KUBECONFIG} --context kind-kind config set-context my-oidc --cluster=kind-kind --user=oidc-user"
    # kubectl --kubeconfig=${KIND_KUBECONFIG} config use-context my-oidc

}

function refresh_kind_spiffe_kubeconfig() {
    get_client_token
    set_spiffe_kubeconfig
    check_spiffe_kubeconfig
}

function check_spiffe_kubeconfig() {
    pe "oc --kubeconfig=${KIND_KUBECONFIG} --context my-oidc whoami"
    pe "kubectl --kubeconfig=${KIND_KUBECONFIG} --context my-oidc get ns"
}

function show_kind_api_server_logs() {
    echo "Show kind cluster api server logs"
    echo "--------------------------------------------------"
    kubectl --kubeconfig=${KIND_KUBECONFIG} --context kind-kind logs -n kube-system -l component=kube-apiserver
    echo "--------------------------------------------------"
}

function show_openid_config() {
    pe "curl https://${OIDC_SERVER}/.well-known/openid-configuration"
}

function main() {
    init
    deploy_spiffe_on_ocp
    register_workloads
    create_client

    prepare_oidc_ca
    create_kind_cluster
    refresh_kind_spiffe_kubeconfig
    return
}

# Function for the 'help' subcommand
help() {
    echo "Usage: $0 {setup-env|enable-addons|deploy-ai-app|deploy-app|all|call|help}"
    echo "deploy        - Deploy spiffe server(with oidc provider), and spire agent"
    echo "main          - Deploy spiffe server(with oidc provider), and spire agent; then create a kind cluster using the oidc provider"
    echo "call          - Call a specific function"
    echo "help          - Display this help message"
    echo "Note: kubectl is required, the KUBECONFIG env must be set."
}

# Check if at least one argument is provided
if [ $# -lt 1 ]; then
    echo "Error: No subcommand provided."
    help
    exit 1
fi

# Parse the first argument as the subcommand
case "$1" in
deploy)
    init
    deploy_spiffe_on_ocp
    ;;
main)
    main
    ;;
help)
    help
    ;;
call)
    init
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
#
#  Below are some useful commands
#
# ########################################################################################

kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://$APP_DOMAIN/ns/spire/sa/spire-agent \
    -selector k8s_sat:cluster:hub \
    -selector k8s_sat:agent_ns:spire \
    -selector k8s_sat:agent_sa:spire-agent \
    -node

kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://$APP_DOMAIN/ns/default/sa/default \
    -parentID spiffe://$APP_DOMAIN/ns/spire/sa/spire-agent \
    -selector k8s:ns:default \
    -selector k8s:sa:default
