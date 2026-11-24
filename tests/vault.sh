#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/bootstrap.sh
source "$ROOT/scripts/bootstrap.sh"
WORK=$(mktemp -d)
trap cleanup EXIT
export VPN_VAULT=vpn-unit-test
TOKEN_FAILURE=false
TRANSPORT_FAILURE=false
HTTP_FIRST=200
printf '0\n' > "$WORK/calls"
if [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]; then
  jq() { command jq -b "$@"; }
fi

sleep() { :; }
curl() {
  local url=${!#} calls
  local output='' header='' body=''
  if [[ $url == http://169.254.169.254/* ]]; then
    if [[ $TOKEN_FAILURE == true ]]; then return 22; fi
    printf '{"access_token":"unit-test-token"}\n'
    return
  fi
  if [[ $TRANSPORT_FAILURE == true ]]; then return 7; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) output=$2 ;;
      --header) header=${2#@} ;;
      --data-binary) body=${2#@} ;;
    esac
    shift
  done
  [[ -n $output && -n $header ]] || return 1
  grep -q '^Authorization: Bearer unit-test-token$' "$header" || return 1
  if [[ -n $body ]]; then
    jq -e '.value | length == 25000' "$body" > /dev/null || return 1
  fi
  calls=$(cat "$WORK/calls")
  printf '%s\n' "$((calls + 1))" > "$WORK/calls"
  printf '{"value":"unit-test-state"}\n' > "$output"
  if [[ $calls == 0 ]]; then printf '%s' "$HTTP_FIRST"; else printf '200'; fi
}

HTTP_FIRST=403
vault_request GET vpn-state
[[ $(cat "$WORK/calls") == 2 ]]
HTTP_FIRST=404
printf '0\n' > "$WORK/calls"
result=0
vault_request GET vpn-state || result=$?
[[ $result == 4 && $(cat "$WORK/calls") == 1 ]]
HTTP_FIRST=401
printf '0\n' > "$WORK/calls"
if (vault_request GET vpn-state) > "$WORK/error.log" 2>&1; then
  fail 'Unexpected authorization failures must not be treated as missing state.'
fi
grep -q 'HTTP 401' "$WORK/error.log"
TOKEN_FAILURE=true
if (vault_request GET vpn-state) > "$WORK/error.log" 2>&1; then
  fail 'IMDS failures must stop the bootstrap.'
fi
grep -q 'Managed identity token request failed' "$WORK/error.log"
TOKEN_FAILURE=false
TRANSPORT_FAILURE=true
if (vault_request GET vpn-state) > "$WORK/error.log" 2>&1; then
  fail 'Transport failures must stop the bootstrap.'
fi
grep -q 'transport request failed' "$WORK/error.log"
TRANSPORT_FAILURE=false
HTTP_FIRST=200
printf '0\n' > "$WORK/calls"
printf '%25000s' '' > "$WORK/at-limit"
put_secret test-at-limit "$WORK/at-limit"
printf '%25001s' '' > "$WORK/over-limit"
if (put_secret test-over-limit "$WORK/over-limit") > "$WORK/error.log" 2>&1; then
  fail 'Oversized Key Vault secrets must be rejected.'
fi
grep -q 'exceeds the Key Vault secret size limit' "$WORK/error.log"
[[ $(cat "$WORK/calls") == 1 ]]
printf 'Key Vault RBAC retry, missing-state distinction, fail-closed token/transport errors, and exact size boundary passed.\n'
