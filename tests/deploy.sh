#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
RETAIL_PID=
trap 'if [[ -n $RETAIL_PID ]] && kill -0 "$RETAIL_PID" 2>/dev/null; then kill "$RETAIL_PID"; fi; rm -rf -- "$TEST_DIR"' EXIT
export TEST_DIR
export AZURE_LOCATION=${AZURE_LOCATION:-denmarkeast}
export VPN_ADMIN_OBJECT_ID=11111111-1111-1111-1111-111111111111
export GITHUB_STEP_SUMMARY="$TEST_DIR/summary"
unset VPN_VM_SIZE VM_SIZE
export EXPECTED_VM_SIZE=Standard_B2ats_v2
export EXISTING=false
export RESTRICTED=false
export NO_PRICES=false
export PAGE_FAILURE=false
export MANY_SKUS=false
export BATCH_FAILURE=false
export EXTENSION_FAILURE=false
if [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]; then
  jq() { command jq -b "$@"; }
  export -f jq
fi

az() {
  local -a arguments=("$@")
  local index
  for ((index=0; index<${#arguments[@]}; index++)); do
    if [[ ${arguments[index]} == --resource-group || $1 == group && $2 == exists && ${arguments[index]} == --name ]]; then
      [[ ${arguments[index+1]} == "vpn_${AZURE_LOCATION}_rg" ]] ||
        { echo 'Deployment used an unexpected resource-group name.' >&2; return 1; }
    fi
  done
  case "$1 $2" in
    'account list-locations') printf '[{"name":"denmarkeast"},{"name":"westeurope"},{"name":"polandcentral"}]\n' ;;
    'vm list-skus')
      if [[ $RESTRICTED == true ]]; then
        printf '[]\n'
      else
        jq -n --argjson many "$MANY_SKUS" '
          def sku($name; $cores; $memory; $arch; $gen; $disabled; $restrictions): {
            name: $name, restrictions: $restrictions,
            capabilities: ({vCPUs: $cores, CpuArchitectureType: $arch, MemoryGB: $memory,
              HyperVGenerations: $gen, TrustedLaunchDisabled: $disabled} | to_entries |
              map({name: .key, value: .value}))
          };
          [sku("Standard_B1s"; "1"; "1"; "x64"; "V1,V2"; "False"; []),
           sku("Standard_B2ats_v2"; "2"; "1"; "x64"; "V2"; "False"; []),
           sku("Standard_D2s_v5"; "2"; "8"; "x64"; "V1,V2"; "False"; []),
           sku("Standard_B2pts_v2"; "2"; "1"; "Arm64"; "V2"; "False"; []),
           sku("Standard_A2_v2"; "2"; "4"; "x64"; "V1"; "False"; []),
           sku("Standard_F2"; "2"; "4"; "x64"; "V2"; "True"; []),
           sku("Standard_B2ts_v2"; "2"; "1"; "x64"; "V2"; "False"; [{type:"Location"}]),
           sku("Standard_TestLowMemory"; "2"; "0.5"; "x64"; "V2"; "False"; [])] +
          if $many then
            [range(1; 41) | sku("Standard_Test2_\(.)"; "2"; "1"; "x64"; "V2"; "False"; [])] +
            [sku("Standard_TestCheapest"; "2"; "1"; "x64"; "V2"; "False"; [])]
          else [] end
        '
      fi
      ;;
    'group exists')
      if [[ $EXISTING == lookup-error ]]; then
        echo 'ERROR: Resource group lookup failed.' >&2
        return 1
      fi
      printf '%s\n' "$EXISTING"
      ;;
    'keyvault list') printf '[{"name":"vpn-test-vault"}]\n' ;;
    'keyvault secret')
      case "$3" in
        list) printf '[{"name":"admin-ssh-private-key"}]\n' ;;
        download)
          while [[ $# -gt 0 ]]; do
            if [[ $1 == --file ]]; then
              cp "$TEST_DIR/stored.key" "$2"
              break
            fi
            shift
          done
          ;;
        *) return 1 ;;
      esac
      ;;
    'account get-access-token')
      local body
      body=$(printf '{"oid":"22222222-2222-2222-2222-222222222222"}' | base64 -w0)
      printf 'header.%s.signature\n' "$body"
      ;;
    'deployment sub')
      [[ $3 == create ]] || return 1
      local arg parameters=
      while [[ $# -gt 0 ]]; do
        arg=$1
        shift
        if [[ $arg == --parameters ]]; then parameters=${1#@}; fi
      done
      [[ -s $parameters ]] || return 1
      printf '%s\n' "$parameters" > "$TEST_DIR/parameter-path"
      jq -erj .parameters.sshKey.value.privateKey "$parameters" > "$TEST_DIR/stored.key"
      chmod 600 "$TEST_DIR/stored.key"
      local public
      public=$(ssh-keygen -y -f "$TEST_DIR/stored.key")
      jq -e --arg public "$public" --arg size "$EXPECTED_VM_SIZE" \
        '.parameters.sshKey.value.publicKey == $public and
         .parameters.vmSize.value == $size and
         .parameters.automationObjectId.value == "22222222-2222-2222-2222-222222222222"' \
        "$parameters" > /dev/null
      printf '{"vaultName":{"value":"vpn-test-vault"},"hostname":{"value":"vpn-test.%s.cloudapp.azure.com"},"vmName":{"value":"vpn-%s-vm"}}\n' \
        "$AZURE_LOCATION" "$AZURE_LOCATION"
      ;;
    'vm get-instance-view')
      local name=
      while [[ $# -gt 0 ]]; do
        if [[ $1 == --name ]]; then name=$2; fi
        shift
      done
      [[ $name == "vpn-${AZURE_LOCATION}-vm" ]] || return 1
      local status=ProvisioningState/succeeded
      if [[ $EXTENSION_FAILURE == true ]]; then status=ProvisioningState/failed; fi
      jq -n --arg status "$status" \
        '[{name:"AADSSHLoginForLinux",statuses:[{code:"ProvisioningState/succeeded"}]},
          {name:"vpn-bootstrap",statuses:[{code:$status}]}]'
      ;;
    *) printf 'Unexpected Azure CLI call: %s\n' "$*" >&2; return 1 ;;
  esac
}
export -f az

curl() {
  local url=${!#} output='' index filter=''
  local -a arguments=("$@")
  for ((index=0; index<${#arguments[@]}; index++)); do
    if [[ ${arguments[index]} == --output ]]; then output=${arguments[index+1]}; fi
    if [[ ${arguments[index]} == --data-urlencode ]]; then filter=${arguments[index+1]}; fi
  done
  [[ -n $output ]] || { echo 'Pricing retries must write to a file, not stdout.' >&2; return 1; }
  if [[ $url == *"\$skip=1000" ]]; then
    if [[ $PAGE_FAILURE == true ]]; then
      echo 'Azure Retail Prices page unavailable after retries (HTTP 429).' >&2
      return 22
    fi
    jq -n --arg region "$AZURE_LOCATION" '{Items: [{
      armSkuName:"Standard_B2ats_v2", armRegionName:$region, retailPrice:0.023,
      productName:"Virtual Machines Basv2 Series", skuName:"B2ats v2", meterName:"B2ats v2",
      type:"Consumption", unitOfMeasure:"1 Hour", currencyCode:"USD", isPrimaryMeterRegion:true
    }], NextPageLink: null}' > "$output"
    return
  fi
  [[ $url == https://prices.azure.com/api/retail/prices\?* && $* == *"armRegionName eq '$AZURE_LOCATION'"* ]] || return 1
  if [[ $MANY_SKUS == true ]]; then
    local names
    names=$(jq -cn --arg filter "$filter" \
      '$filter | [match("armSkuName eq \u0027([A-Za-z0-9_-]+)\u0027"; "g") | .captures[0].string]') || return 1
    if ! jq -e 'length > 0 and length <= 10' <<< "$names" > /dev/null ||
      ! jq -ne --arg url "$url" --arg filter "${filter#*=}" \
        '($url | length) + 9 + ($filter | @uri | length) < 2048' > /dev/null; then
      echo 'Pricing query exceeded API complexity or URL limits (HTTP 404).' >&2
      printf '404'
      return 22
    fi
    if [[ $BATCH_FAILURE == true ]] &&
      jq -e 'index("Standard_TestCheapest") != null' <<< "$names" > /dev/null; then
      echo 'Last pricing batch unavailable (HTTP 404).' >&2
      printf '404'
      return 22
    fi
    printf '%s\n' "$names" >> "$TEST_DIR/price-batches"
    jq -n --argjson names "$names" --arg region "$AZURE_LOCATION" '
      {Items: [$names[] | . as $size | {
        armSkuName:$size, armRegionName:$region,
        retailPrice:(if $size == "Standard_TestCheapest" then 0.02
          elif $size == "Standard_B2ats_v2" then 0.023 else 0.1 end),
        productName:"Virtual Machines Example Series", skuName:$size, meterName:$size,
        type:"Consumption", unitOfMeasure:"1 Hour", currencyCode:"USD", isPrimaryMeterRegion:true
      }], NextPageLink:null}
    ' > "$output"
    return
  fi
  local size=${VPN_VM_SIZE:-${VM_SIZE:-}} expected_filter
  if [[ -n $size ]]; then
    expected_filter="and (armSkuName eq '$size')"
  else
    expected_filter="and (armSkuName eq 'Standard_B2ats_v2' or armSkuName eq 'Standard_D2s_v5')"
  fi
  [[ $* == *"$expected_filter"* ]] ||
    { echo 'Pricing request must include only eligible SKUs.' >&2; return 1; }
  if [[ -n ${RETAIL_HTTP_URL:-} ]]; then
    command curl --noproxy '*' "${@:1:$#-1}" --max-time 1 "$RETAIL_HTTP_URL"
    return
  fi
  if [[ $NO_PRICES == true ]]; then printf '{"Items":[],"NextPageLink":null}\n' > "$output"; return; fi
  jq -n --arg region "$AZURE_LOCATION" '
    def price($size; $rate): {
      armSkuName:$size, armRegionName:$region, retailPrice:$rate,
      productName:"Virtual Machines Example Series", skuName:$size, meterName:$size,
      type:"Consumption", unitOfMeasure:"1 Hour", currencyCode:"USD", isPrimaryMeterRegion:true
    };
    {Items: [
      price("Standard_D2s_v5"; 0.1),
      (price("Standard_D2s_v5"; 0.001) | .meterName += " Spot"),
      (price("Standard_D2s_v5"; 0.002) | .skuName += " Low Priority"),
      (price("Standard_D2s_v5"; 0.003) | .productName += " Windows"),
      (price("Standard_D2s_v5"; 0.004) | .type = "Reservation"),
      price("Standard_B1s"; 0.012), price("Standard_B2pts_v2"; 0.009),
      price("Standard_A2_v2"; 0.008), price("Standard_F2"; 0.007), price("Standard_B2ts_v2"; 0.006),
      price("Standard_TestLowMemory"; 0.005)
    ], NextPageLink:"https://prices.azure.com:443/api/retail/prices?$skip=1000"}
  ' > "$output"
}
export -f curl

sleep() {
  # Keep retry-limit cases fast; timing cases use real delays.
  case "${RETAIL_HTTP_URL:-}" in
    */retry-limit|*/exhausted|*/retry-budget) return ;;
    *) command sleep "$@" ;;
  esac
}
export -f sleep

bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/first.log" 2>&1
grep -Fq 'Standard_B2ats_v2. Estimated cost: USD 0.023/hour (~USD 16.79/month' "$TEST_DIR/first.log"
grep -Fq "Regional VPN deployed in $AZURE_LOCATION: Standard_B2ats_v2." "$TEST_DIR/first.log"
grep -Fq '## Regional VPN deployed' "$TEST_DIR/summary"
grep -Fxq -- "- Region: \`$AZURE_LOCATION\`" "$TEST_DIR/summary"
grep -Fxq -- "- VM size: \`$EXPECTED_VM_SIZE\`" "$TEST_DIR/summary"
grep -Fq 'Estimated VM cost: USD 0.023/hour' "$TEST_DIR/summary"
first_key=$(sha256sum "$TEST_DIR/stored.key" | cut -d ' ' -f1)
[[ ! -e $(cat "$TEST_DIR/parameter-path") ]]
export EXISTING=true
VPN_VM_SIZE=Standard_B1s EXPECTED_VM_SIZE=Standard_B1s bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/redeploy.log" 2>&1
grep -Fq 'Standard_B1s. Estimated cost: USD 0.012/hour (~USD 8.76/month' "$TEST_DIR/redeploy.log"
[[ $(sha256sum "$TEST_DIR/stored.key" | cut -d ' ' -f1) == "$first_key" ]]
[[ ! -e $(cat "$TEST_DIR/parameter-path") ]]
if grep -Eq 'BEGIN OPENSSH PRIVATE KEY|vpn-test-vault|vpn-test\.[a-z]+\.cloudapp\.azure\.com' \
  "$TEST_DIR/first.log" "$TEST_DIR/redeploy.log" "$TEST_DIR/summary"; then
  echo 'Private key, hostname, or vault name leaked to deployment output.' >&2
  exit 1
fi
if EXISTING=lookup-error bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'A failed resource group lookup must stop deployment.' >&2
  exit 1
fi
grep -Fq 'ERROR: Resource group lookup failed.' "$TEST_DIR/error.log"
if AZURE_LOCATION='region;unsafe' bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Invalid region must fail.' >&2
  exit 1
fi
grep -q 'Invalid Azure region' "$TEST_DIR/error.log"
if VPN_VM_SIZE=Standard_B1s RESTRICTED=true bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Unavailable VM size must fail without a fallback.' >&2
  exit 1
fi
grep -q 'VM size is unavailable or restricted' "$TEST_DIR/error.log"
if NO_PRICES=true bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Automatic selection must fail when pricing is unavailable.' >&2
  exit 1
fi
grep -q 'Could not price an eligible 2-vCPU VM' "$TEST_DIR/error.log"
if PAGE_FAILURE=true bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Automatic selection must fail rather than use an incomplete price list.' >&2
  exit 1
fi
grep -q 'Could not price an eligible 2-vCPU VM' "$TEST_DIR/error.log"
NO_PRICES=true VM_SIZE=Standard_B1s EXPECTED_VM_SIZE=Standard_B1s \
  bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/explicit.log" 2>&1
grep -Fq 'Warning: Azure Retail Prices estimate unavailable for Standard_B1s' "$TEST_DIR/explicit.log"
if EXTENSION_FAILURE=true bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Unhealthy VM extensions must fail deployment verification.' >&2
  exit 1
fi
grep -q 'VM extensions did not both report successful provisioning' "$TEST_DIR/error.log"
MANY_SKUS=true EXPECTED_VM_SIZE=Standard_TestCheapest \
  bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/batches.log"
grep -Fq 'Standard_TestCheapest. Estimated cost: USD 0.02/hour (~USD 14.60/month' "$TEST_DIR/batches.log"
jq -se 'length == 5 and ([.[][]] | length) == 43 and ([.[][]] | unique | length) == 43' \
  "$TEST_DIR/price-batches" > /dev/null
if MANY_SKUS=true BATCH_FAILURE=true bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Automatic selection must fail when any pricing batch is unavailable.' >&2
  exit 1
fi
grep -q 'Could not price an eligible 2-vCPU VM' "$TEST_DIR/error.log"

"${PYTHON:-python3}" - "$TEST_DIR" <<'PY' &
import json
import os
import pathlib
import sys
import time
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, HTTPServer

directory = pathlib.Path(sys.argv[1])
failures = {"throttled": 3, "retry-limit": 9, "exhausted": 10, "partial": 0,
            "retry-after": 1, "retry-date": 1, "retry-budget": 1}
counts = {kind: 0 for kind in failures}
arrival_times = {kind: [] for kind in ("throttled", "retry-after", "retry-date")}
payload = json.dumps({"Items": [{
    "armSkuName": "Standard_B2ats_v2", "armRegionName": os.environ["AZURE_LOCATION"],
    "retailPrice": 0.023, "productName": "Virtual Machines Basv2 Series",
    "skuName": "B2ats v2", "meterName": "B2ats v2", "type": "Consumption",
    "unitOfMeasure": "1 Hour", "currencyCode": "USD", "isPrimaryMeterRegion": True,
}], "NextPageLink": None}).encode()

class Prices(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        kind = self.path.split("?")[0].strip("/")
        if kind == "stop":
            self.send_response(200)
            self.end_headers()
            return
        counts[kind] += 1
        if kind in arrival_times:
            arrival_times[kind].append(time.monotonic())
        if counts[kind] <= failures[kind]:
            retry_after = "1"
            if kind == "retry-after":
                retry_after = "00002"
            elif kind == "retry-date":
                retry_after = formatdate(time.time() + 3, usegmt=True)
            elif kind == "retry-budget":
                retry_after = "901"
            self.send_response(429)
            self.send_header("Retry-After", retry_after)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if kind == "partial" and counts[kind] == 1:
            self.wfile.write(payload[:len(payload) // 2])
            self.wfile.flush()
            time.sleep(2)
        else:
            self.wfile.write(payload)

with HTTPServer(("127.0.0.1", 0), Prices) as server:
    server.timeout = 10
    (directory / "price-port").write_text(str(server.server_port))
    for _ in range(32):
        server.handle_request()
delays = {kind: [end - start for start, end in zip(times, times[1:])]
          for kind, times in arrival_times.items()}
result = {**counts, "delays": delays}
(directory / "price-requests.json").write_text(json.dumps(result))
PY
RETAIL_PID=$!
for _ in {1..50}; do
  [[ -s $TEST_DIR/price-port ]] && break
  sleep 0.1
done
[[ -s $TEST_DIR/price-port ]] || { echo 'Local pricing test server did not start.' >&2; exit 1; }
retail_url="http://127.0.0.1:$(cat "$TEST_DIR/price-port")"
for scenario in throttled retry-limit partial retry-after retry-date; do
  RETAIL_HTTP_URL="$retail_url/$scenario" \
    bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/$scenario.log" 2>&1
  grep -Fq 'Standard_B2ats_v2. Estimated cost: USD 0.023/hour' "$TEST_DIR/$scenario.log"
done
if RETAIL_HTTP_URL="$retail_url/exhausted" bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Pricing must stop after nine retries rather than attempt an eleventh request.' >&2
  exit 1
fi
grep -q 'Could not price an eligible 2-vCPU VM' "$TEST_DIR/error.log"
if RETAIL_HTTP_URL="$retail_url/retry-budget" bash "$ROOT/scripts/deploy.sh" > "$TEST_DIR/error.log" 2>&1; then
  echo 'Pricing must stop when Retry-After exceeds the retry budget.' >&2
  exit 1
fi
grep -q 'Azure Retail Prices retry budget exhausted' "$TEST_DIR/error.log"
command curl --noproxy '*' --fail --silent --show-error --max-time 5 "$retail_url/stop" > /dev/null
wait "$RETAIL_PID"
RETAIL_PID=
jq -e '.throttled == 4 and .["retry-limit"] == 10 and .exhausted == 10 and .partial == 2 and
  .["retry-after"] == 2 and .["retry-date"] == 2 and .["retry-budget"] == 1 and
  .delays.throttled[1] > .delays.throttled[0] and .delays.throttled[2] > .delays.throttled[1] and
  .delays["retry-after"][0] >= 2 and .delays["retry-date"][0] >= 2' "$TEST_DIR/price-requests.json" > /dev/null ||
  { cat "$TEST_DIR/price-requests.json" >&2; echo 'Pricing retry counts or exponential backoff were incorrect.' >&2; exit 1; }
printf 'Regional deployment, bounded pricing batches and global minimum, exponential backoff, nine-retry success and exhaustion, Retry-After and retry budgets, partial-download retries, explicit override, pricing failures, stable recovery SSH keys, secure parameter cleanup, and extension health passed (mock Azure CLI and local Retail Prices API).\n'
