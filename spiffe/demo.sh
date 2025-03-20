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
export $(cut -d= -f1 ${DEMO_DIR}/config/variable.txt)

HUB_KUBECONFIG="${KUBECONFIG:=${DEMO_DIR}/credentials/ocm_hub.kubeconfig}"
SPIRE_KIND_KUBECONFIG="${SPIRE_KIND_KUBECONFIG:=${DEMO_DIR}/manifests/credentials/spire_kind.kubeconfig}"
OIDC_PROVIDER_CA_PATH="${DEMO_DIR}/manifests/credentials/oidc_ca.crt"
CLIENT_TOKEN_PATH="${DEMO_DIR}/manifests/credentials/client_token"

KEYCLOAK_KIND_KUBECONFIG="${KEYCLOAK_KIND_KUBECONFIG:=${DEMO_DIR}/manifests/credentials/keycloak/keycloak_kind.kubeconfig}"
KEYCLOAK_CLIENT_KUBECONFIG="${KEYCLOAK_CLIENT_KUBECONFIG:=${DEMO_DIR}/manifests/credentials/keycloak/keycloak_client.kubeconfig}"
KEYCLOAK_CERT_PATH="${DEMO_DIR}/manifests/credentials/keycloak/certificate.pem"
KEYCLOAK_KEY_PATH="${DEMO_DIR}/manifests/credentials/keycloak/key.pem"

echo "HUB_KUBECONFIG: ${HUB_KUBECONFIG}"
echo "SPIRE_KIND_KUBECONFIG: ${SPIRE_KIND_KUBECONFIG}"
# echo "KEYCLOAK_CLIENT_KUBECONFIG: ${KEYCLOAK_CLIENT_KUBECONFIG}"
echo "OIDC_PROVIDER_CA_PATH: ${OIDC_PROVIDER_CA_PATH}"

function init() {
    echo "Extract the app domain name, cluster hostname, and oidc provider address"
    export APP_DOMAIN=$(oc get cm -n openshift-config-managed console-public -o go-template="{{ .data.consoleURL }}" | sed 's@https://@@; s/^[^.]*\.//')
    echo "APP_DOMAIN: ${APP_DOMAIN}"

    export CLUSTER_HOSTNAME=$(echo "${APP_DOMAIN}" | awk -F'.' '{print $2}')
    echo "CLUSTER_HOSTNAME: ${CLUSTER_HOSTNAME}"

    export OIDC_SERVER=oidc-discovery.${APP_DOMAIN}
    echo "OIDC_SERVER: ${OIDC_SERVER}"

    export SPIRE_SERVER=spire-server.${APP_DOMAIN}
    echo "SPIRE_SERVER: ${SPIRE_SERVER}"

    export KEYCLOAK_SERVER=keycloak.${APP_DOMAIN}
    echo "KEYCLOAK_SERVER: ${KEYCLOAK_SERVER}"

    export OIDC_PROVIDER_CA_PATH

    USER_ID=$(id -u)
    USER_NAME=$(id -un)
    export USER_ID
    export USER_NAME
}

function deploy_spire_on_ocp() {
    p "Create OCP SecurityContextConstraints(scc), and binding permissions for spire service account"
    pei "envsubst < ${DEMO_DIR}/manifests/spire-namespace.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-spire-scc.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-spire-scc-clusterrole.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-spire-scc-rolebinding-spire.yaml | kubectl apply -f -"

    deploy_spire_server_with_oidc_provider
    deploy_spire_agent
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
    p "Expose the spire server via the OCP route"
    pei "envsubst < ${DEMO_DIR}/manifests/ocp/ocp-route-spire-server.yaml | kubectl apply -f -"
}

function deploy_spire_agent() {
    p "Deploy spire agent"
    envsubst <${DEMO_DIR}/manifests/spire-namespace.yaml | kubectl apply -f -
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-account.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-cluster-role.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-configmap.yaml | kubectl apply -f -"
    pei "envsubst < ${DEMO_DIR}/manifests/agent/agent-daemonset.yaml | kubectl apply -f -"
}

function deploy_spire_local_agent() {
    p "Deploy local spire agent"

    echo "Create a join token for the local agent"
    p "kubectl exec -n spire -it spire-server-0 -c spire-server -- /opt/spire/bin/spire-server token generate \
        -spiffeID spiffe://${APP_DOMAIN}/host/mac 2>&1 | grep 'Token: ' | awk '{print \$2}' | tr -d '\r'"
    JOIN_TOKEN=$(kubectl exec -n spire -it spire-server-0 -c spire-server -- /opt/spire/bin/spire-server token generate \
        -spiffeID spiffe://${APP_DOMAIN}/host/mac | grep 'Token: ' | awk '{print $2}' | tr -d '\r')
    export JOIN_TOKEN

    echo "Join token: ${JOIN_TOKEN}, USER_ID: ${USER_ID}, USER_NAME: ${USER_NAME}"
    p "Join the local agent"
    # pei "envsubst < ${DEMO_DIR}/manifests/agent/mac-agent.conf | nohup ${SPIRE_AGENT_BIN} run -config - &"
    envsubst <${DEMO_DIR}/manifests/agent/mac-agent.conf >${DEMO_DIR}/manifests/credentials/spire_local_agent.conf
    p "Use the following command to start the spire agent on the local host:\n${SPIRE_AGENT_BIN} run -config ${DEMO_DIR}/manifests/credentials/spire_local_agent.conf"
    p "Create a entry for the current user in the local agent"
    pei "kubectl exec -n spire -it spire-server-0 -c spire-server -- \
        /opt/spire/bin/spire-server entry create -parentID spiffe://${APP_DOMAIN}/host/mac \
        -spiffeID spiffe://${APP_DOMAIN}/host/mac/user/${USER_NAME} \
        -selector unix:uid:${USER_ID}"

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

function create_spire_kind_cluster() {
    pe "envsubst < ${DEMO_DIR}/manifests/kind/cluster-config.yaml | kind create cluster --name spire-client \
       --kubeconfig=${SPIRE_KIND_KUBECONFIG} --config -"
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

function get_local_client_token() {
    p "Get a local client Token by spire-agent api fetch jwt"
    CLIENT_TOKEN=$(${SPIRE_AGENT_BIN} api fetch jwt -audience kube \
        -socketPath ${SPIRE_LOCAL_SOCKET_PATH} | awk '/token\(/ {getline; print $1}')
    echo "${CLIENT_TOKEN}" >${CLIENT_TOKEN_PATH}
    export CLIENT_TOKEN
    echo "Local client Token created"
}

function set_spire_kubeconfig() {
    if [ -z "${!CLIENT_TOKEN}" ]; then
        if [ -f "$CLIENT_TOKEN_PATH" ]; then
            export "CLIENT_TOKEN"=$(cat "$CLIENT_TOKEN_PATH")
            echo "set CLIENT_TOKEN from ${CLIENT_TOKEN_PATH}"
        else
            echo "File $CLIENT_TOKEN_PATH not found!"
        fi
    fi

    p "Grant permissions for the spire client"
    pei "envsubst <${DEMO_DIR}/manifests/kind/spire-user-binding.yaml | kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client apply -f -"

    p "Construct a kubeconfig using the client token"
    echo "kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client config set-credentials oidc-user --token=CLIENT_TOKEN"
    kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client config set-credentials oidc-user --token=${CLIENT_TOKEN}
    pei "kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client config set-context my-oidc --cluster=kind-spire-client --user=oidc-user"

    p "render the spire_fetch_token file and copy it into PATH"
    pei "envsubst '${SPIRE_AGENT_BIN} ${SPIRE_LOCAL_SOCKET_PATH}' <${DEMO_DIR}/manifests/kind/spire_fetch_token.sh > $HOME/local/bin/spire_fetch_token.sh"
    pei "chmod +x $HOME/local/bin/spire_fetch_token.sh"
    pei "kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client config set-credentials oidc-login --exec-api-version=client.authentication.k8s.io/v1 \
        --exec-command=spire_fetch_token.sh \
        --exec-interactive-mode=IfAvailable"
    pei "kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client config set-context oidc-exec --cluster=kind-spire-client --user=oidc-login"

    # kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} config use-context my-oidc

}

function refresh_spire_kind_kubeconfig() {
    # get_client_token
    get_local_client_token
    set_spire_kubeconfig
    check_spire_kind_kubeconfig
}

function check_spire_kind_kubeconfig() {
    pe "oc --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context my-oidc whoami"
    pe "kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context my-oidc get ns"
    pe "oc --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context oidc-exec whoami"
    pe "kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context oidc-exec get ns"
}

function show_spire_kind_api_server_logs() {
    echo "Show kind cluster api server logs"
    echo "--------------------------------------------------"
    kubectl --kubeconfig=${SPIRE_KIND_KUBECONFIG} --context kind-spire-client logs -n kube-system -l component=kube-apiserver
    echo "--------------------------------------------------"
}

function show_openid_config() {
    pe "curl https://${OIDC_SERVER}/.well-known/openid-configuration"
}

function install_keycloak() {
    echo 'Ensure the keycloak operator is installed in the "keycloak" namespace, if not you can install it from the ocp console'
    # p "Create the keycloak key and cert"
    # envsubst <${DEMO_DIR}/manifests/keycloak/openssl.cnf | openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    #     -keyout ${KEYCLOAK_KEY_PATH} -out ${KEYCLOAK_CERT_PATH} -config -

    pe "envsubst <${DEMO_DIR}/manifests/keycloak/keycloak.yaml | kubectl apply -f -"
    pe "kubectl create secret tls keycloak-tls-secret -n keycloak \
        --cert ${KEYCLOAK_CERT_PATH} \
        --key ${KEYCLOAK_KEY_PATH}"

    echo "--------------------------------------------------"
    echo "Keycloak installed"
    echo "URL: https://${KEYCLOAK_SERVER}"
    echo "You can get the initial login credential by:"
    echo "  kubectl get secret -n keycloak my-keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d"
    echo "  the initial username is temp-admin"
    echo "--------------------------------------------------"
}

function set_up_keycloak_client() {
    echo '1. login to the keycloak console'
    echo '2. create a realm ${KEYCLOAK_REALM_NAME}, eg: ocm'
    echo '3. Click "Client" to create a keycloak client, Set "Client ID" to ${KEYCLOAK_OIDC_CLIENT_ID}, eg: ocp-test, enable "Client authtication",
          Provide the Valid redirect URIs: "https://oauth-openshift.apps.<client-cluster-host>.dev04.red-chesterfield.com/oauth2callback/*"'
    echo '4. Click "Users" -> "Add user"'
    echo '5. After the user created, click "Credentials" to create a password for the user'
}

function configure_keycloak_as_oidc_provider() {
    if [ -z "${KEYCLOAK_OIDC_CLIENT_SECRET}" ]; then
        echo "KEYCLOAK_OIDC_CLIENT_SECRET is not set or empty"
        exit 1
    fi
    p "Configure keycloak as the oidc provider, keycloak realm name: ${KEYCLOAK_REALM_NAME}, oidc client id: ${KEYCLOAK_OIDC_CLIENT_ID}"
    pei "oc --kubeconfig=${KEYCLOAK_CLIENT_KUBECONFIG} create configmap -n openshift-config openid-ca-keycloak --from-file=ca.crt=${KEYCLOAK_CERT_PATH}"
    p 'oc --kubeconfig=${KEYCLOAK_CLIENT_KUBECONFIG} create secret generic -n openshift-config openid-client-secret-keycloak --from-literal=clientSecret=${KEYCLOAK_OIDC_CLIENT_SECRET}'
    oc --kubeconfig=${KEYCLOAK_CLIENT_KUBECONFIG} create secret generic -n openshift-config openid-client-secret-keycloak --from-literal=clientSecret=${KEYCLOAK_OIDC_CLIENT_SECRET}
    pei "envsubst <${DEMO_DIR}/manifests/keycloak/oauth.yaml | oc --kubeconfig=${KEYCLOAK_CLIENT_KUBECONFIG} apply -f -"

    p "Check the oauth configure status"
    pei "oc --kubeconfig=${KEYCLOAK_CLIENT_KUBECONFIG} get oauth cluster -oyaml"
    pei "oc --kubeconfig=${KEYCLOAK_CLIENT_KUBECONFIG} get clusteroperators.config.openshift.io authentication -oyaml"
}

function set_up_keycloak_oidc_plugin_client() {
    set_up_keycloak_client

    echo '6. create client scope "groups", enable "Include in token scope"'
    echo '7. create a mapper for the client scope "groups", "Configure a new mapper" -> "Group Membership", "Token Claim Name" should be "groups", enable "Add to access token", disable "Full group path"(otherwise, the groups you got would be "/k8s-admins")'
    echo '8. add "http://localhost:8000/*" into the the "Valid redirect URIs" for the keycloak client created at step 3'
    echo '9. enable the "groups" client scope for the client'
    echo '10. create a group "k8s-admins"'
    echo '11. join the user created at step 4 to the group "k8s-admins"'
}

function create_keycloak_kind_cluster() {
    pe "envsubst < ${DEMO_DIR}/manifests/kind/cluster-config-keycloak.yaml | kind create cluster --name keycloak-client \
       --kubeconfig=${KEYCLOAK_KIND_KUBECONFIG} --config -"
}

function set_keycloak_kubeconfig() {
    if [ -z "${KEYCLOAK_OIDC_CLIENT_SECRET}" ]; then
        echo "KEYCLOAK_OIDC_CLIENT_SECRET is not set or empty"
        exit 1
    fi

    p "Grant permissions for the keycloak group"
    pei "envsubst <${DEMO_DIR}/manifests/kind/keycloak-user-binding.yaml | kubectl --kubeconfig=${KEYCLOAK_KIND_KUBECONFIG} --context kind-keycloak-client apply -f -"

    p "Construct a kubeconfig using the oidc-login plugin"
    kubectl --kubeconfig=${KEYCLOAK_KIND_KUBECONFIG} --context kind-keycloak-client \
        config set-credentials keycloak-oidc-login --exec-api-version=client.authentication.k8s.io/v1beta1 \
        --exec-command=kubectl --exec-arg=oidc-login --exec-arg=get-token \
        --exec-arg=--oidc-issuer-url=https://${KEYCLOAK_SERVER}/realms/${KEYCLOAK_REALM_NAME} \
        --exec-arg=--oidc-client-id=ocp-test --exec-arg=--oidc-extra-scope="groups email openid" \
        --exec-arg=--oidc-client-secret=${KEYCLOAK_OIDC_CLIENT_SECRET} --exec-arg=--insecure-skip-tls-verify

    pei "kubectl --kubeconfig=${KEYCLOAK_KIND_KUBECONFIG} --context kind-keycloak-client config set-context keyclock-oidc --cluster=kind-keycloak-client --user=keycloak-oidc-login"
    pe "kubectl --kubeconfig=${KEYCLOAK_KIND_KUBECONFIG} --context kind-keycloak-client get ns"
}

function create_spire_kind_cluster_from_scratch() {
    prepare_oidc_ca
    create_spire_kind_cluster
    refresh_spire_kind_kubeconfig
}

function main() {
    init
    deploy_spire_on_ocp
    register_workloads
    create_client

    create_spire_kind_cluster_from_scratch
    return
}

# Function for the 'help' subcommand
help() {
    echo "Usage: $0 {setup-env|enable-addons|deploy-ai-app|deploy-app|all|call|help}"
    echo "deploy        - Deploy spire server(with oidc provider), and spire agent"
    echo "main          - Deploy spire server(with oidc provider), and spire agent; then create a kind cluster using the oidc provider"
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
    deploy_spire_on_ocp
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

kubectl exec -n spire -it spire-server-0 -c spire-server -- \
    /opt/spire/bin/spire-server entry create \
    -parentID spiffe://apps.server-foundation-sno-lite-bdh5w.dev04.red-chesterfield.com/host/mac \
    -spiffeID spiffe://apps.server-foundation-sno-lite-bdh5w.dev04.red-chesterfield.com/host/mac/user/jian \
    -selector unix:uid:501
