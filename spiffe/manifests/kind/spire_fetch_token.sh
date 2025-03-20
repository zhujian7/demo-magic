#!/bin/bash
TOKEN=$(${SPIRE_AGENT_BIN} api fetch jwt -audience kube \
  -socketPath ${SPIRE_LOCAL_SOCKET_PATH} -output json | jq -r '.[0].svids[0].svid')
cat <<EOF
{
  "apiVersion": "client.authentication.k8s.io/v1",
  "kind": "ExecCredential",
  "status": {
    "token": "${TOKEN}"
  }
}
EOF
