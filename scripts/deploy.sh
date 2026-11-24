#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${AZURE_LOCATION:?Set AZURE_LOCATION to an Azure region short name.}"
: "${VPN_ADMIN_OBJECT_ID:?Set VPN_ADMIN_OBJECT_ID to an Entra user or group object ID.}"
VM_SIZE=${VPN_VM_SIZE:-${VM_SIZE:-}}
[[ $AZURE_LOCATION =~ ^[a-z0-9]+$ ]] || { echo 'Invalid Azure region.' >&2; exit 1; }
[[ $VPN_ADMIN_OBJECT_ID =~ ^[a-fA-F0-9-]{36}$ ]] || { echo 'Invalid admin object ID.' >&2; exit 1; }
[[ -z $VM_SIZE || $VM_SIZE =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid VM size.' >&2; exit 1; }

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

az account list-locations -o json > "$WORK/locations.json"
jq -e --arg region "$AZURE_LOCATION" 'any(.[]; .name == $region)' "$WORK/locations.json" > /dev/null ||
  { echo 'Region is not available in this subscription.' >&2; exit 1; }

size_filter=()
if [[ -n $VM_SIZE ]]; then size_filter=(--size "$VM_SIZE"); fi
az vm list-skus --location "$AZURE_LOCATION" --resource-type virtualMachines \
  "${size_filter[@]}" --all -o json > "$WORK/skus.json"
jq --arg size "$VM_SIZE" '
  def capabilities: [.capabilities[]? | {key: .name, value: .value}] | from_entries;
  [.[] | select((.restrictions | length) == 0) |
    if $size != "" then select(.name == $size)
    else select(capabilities |
      .CpuArchitectureType == "x64" and
      .vCPUs == "2" and (.vCPUsAvailable // .vCPUs) == "2" and
      (.MemoryGB | tonumber? >= 1) and
      ((.HyperVGenerations // "") | split(",") | index("V2")) != null and
      ((.TrustedLaunchDisabled // "false") | ascii_downcase) != "true")
    end | .name]
' "$WORK/skus.json" > "$WORK/candidates.json"
jq -e 'length > 0' "$WORK/candidates.json" > /dev/null ||
  { echo 'VM size is unavailable or restricted in this region. Set VPN_VM_SIZE to an available SKU.' >&2; exit 1; }

retail_prices() {
  local url filter sku_filter attempt status result delay wait started retry_after retry_time now
  # Bound both OData complexity and URL length, not just the returned meter count.
  jq -r --arg quote "'" '
    range(0; length; 10) as $start |
    .[$start:$start + 10] | map("armSkuName eq \($quote)\(.)\($quote)") | join(" or ")
  ' "$WORK/candidates.json" > "$WORK/price-filters.txt" || return 1
  while IFS= read -r sku_filter; do
    url='https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&meterRegion=%27primary%27'
    filter="serviceName eq 'Virtual Machines' and armRegionName eq '$AZURE_LOCATION' and priceType eq 'Consumption' and ($sku_filter)"
    local -a query=(--get --data-urlencode "\$filter=$filter")
    while [[ -n $url ]]; do
      case "$url" in
        https://prices.azure.com/api/retail/prices\?*|https://prices.azure.com:443/api/retail/prices\?*) ;;
        *) echo 'Unexpected Azure Retail Prices pagination URL.' >&2; return 1 ;;
      esac
      delay=1
      started=$SECONDS
      for attempt in {0..9}; do
        if ((SECONDS - started >= 900)); then
          echo 'Azure Retail Prices retry budget exhausted.' >&2
          return 1
        fi
        : > "$WORK/prices-headers.txt"
        if status=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
          --dump-header "$WORK/prices-headers.txt" --write-out '%{http_code}' \
          --output "$WORK/prices-page.json" "${query[@]}" "$url"); then
          break
        else
          result=$?
        fi
        case "$result:$status" in
          5:*|6:*|28:*|22:408|22:429|22:500|22:502|22:503|22:504) ;;
          *) return 1 ;;
        esac
        if ((attempt == 9)); then return 1; fi
        wait=$delay
        retry_after=$(awk '
          /^HTTP\// { value = "" }
          tolower($0) ~ /^retry-after:/ {
            sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); value = $0
          }
          END { print value }
        ' "$WORK/prices-headers.txt") || return 1
        if [[ $retry_after =~ ^[0-9]+$ ]]; then
          # Strip leading zeros so Bash does not interpret the delay as octal.
          retry_after=${retry_after#"${retry_after%%[!0]*}"}
          retry_after=${retry_after:-0}
          if ((${#retry_after} > 3)); then
            echo 'Azure Retail Prices Retry-After exceeds the retry budget.' >&2
            return 1
          fi
          if ((retry_after > wait)); then wait=$retry_after; fi
        elif [[ -n $retry_after ]]; then
          if retry_time=$(LC_ALL=C date -d "$retry_after" +%s); then
            now=$(date +%s) || return 1
            retry_time=$((retry_time - now))
            if ((retry_time > wait)); then wait=$retry_time; fi
          else
            echo 'Warning: ignoring invalid Azure Retail Prices Retry-After header.' >&2
          fi
        fi
        if ((SECONDS - started + wait >= 900)); then
          echo 'Azure Retail Prices retry budget exhausted.' >&2
          return 1
        fi
        printf 'Retrying Azure Retail Prices (%s/9, HTTP %s) in %s seconds.\n' \
          "$((attempt + 1))" "$status" "$wait" >&2
        sleep "$wait" || return 1
        delay=$((delay * 2))
      done
      jq -ce '.Items | arrays' "$WORK/prices-page.json" || return 1
      url=$(jq -er '.NextPageLink // "" | strings' "$WORK/prices-page.json") || return 1
      query=()
    done
  done < "$WORK/price-filters.txt"
}

# Rank only regular Linux compute meters; Spot and Windows share the same ARM SKU names.
if quote=$(retail_prices | jq -ers --slurpfile candidates "$WORK/candidates.json" --arg region "$AZURE_LOCATION" '
  [.[][] | .armSkuName as $sku | select($candidates[0] | index($sku)) |
    select(.armRegionName == $region and .type == "Consumption" and
      .unitOfMeasure == "1 Hour" and .currencyCode == "USD" and .isPrimaryMeterRegion == true) |
    select(.productName | startswith("Virtual Machines ")) |
    select([.productName, .skuName, .meterName] | join(" ") | test("Windows|Spot|Low Priority"; "i") | not) |
    select(.retailPrice | type == "number" and . > 0)] |
  min_by([.retailPrice, .armSkuName]) // empty |
  [.armSkuName, .retailPrice, (.retailPrice * 730)] | @tsv
'); then
  IFS=$'\t' read -r VM_SIZE hourly monthly <<< "$quote"
  LC_NUMERIC=C printf -v COMPUTE_COST 'USD %s/hour (~USD %.2f/month at 730 hours; compute only)' "$hourly" "$monthly"
elif [[ -z $VM_SIZE ]]; then
  echo 'Could not price an eligible 2-vCPU VM from Azure Retail Prices. Set VPN_VM_SIZE to select a SKU explicitly.' >&2
  exit 1
else
  echo "Warning: Azure Retail Prices estimate unavailable for $VM_SIZE in $AZURE_LOCATION." >&2
  COMPUTE_COST='Unavailable (Azure Retail Prices)'
fi
printf 'VM size in %s: %s. Estimated cost: %s.\n' "$AZURE_LOCATION" "$VM_SIZE" "$COMPUTE_COST"

RG="vpn_${AZURE_LOCATION}_rg"
GROUP_EXISTS=$(az group exists --name "$RG" -o tsv)
if [[ $GROUP_EXISTS == true ]]; then
  az keyvault list --resource-group "$RG" -o json > "$WORK/vaults.json"
  [[ $(jq length "$WORK/vaults.json") -le 1 ]] || { echo 'Ambiguous regional vaults.' >&2; exit 1; }
  VAULT=$(jq -r '.[0].name // empty' "$WORK/vaults.json")
  if [[ -n $VAULT ]]; then
    az keyvault secret list --vault-name "$VAULT" -o json > "$WORK/secrets.json"
    if jq -e 'any(.[]; .name == "admin-ssh-private-key")' "$WORK/secrets.json" > /dev/null; then
      az keyvault secret download --vault-name "$VAULT" --name admin-ssh-private-key \
        --file "$WORK/admin.key" --encoding utf-8 --output none
    fi
  fi
fi

if [[ ! -s $WORK/admin.key ]]; then
  ssh-keygen -q -t ed25519 -N '' -C regional-vpn-recovery -f "$WORK/admin.key"
fi
ssh-keygen -y -f "$WORK/admin.key" > "$WORK/admin.pub"

# Decode only the caller object ID locally; never log the access token.
AUTOMATION_OBJECT_ID=$(az account get-access-token --query accessToken -o tsv |
  jq -Rer 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson | .oid')
[[ $AUTOMATION_OBJECT_ID =~ ^[a-fA-F0-9-]{36}$ ]] ||
  { echo 'Could not determine automation principal object ID.' >&2; exit 1; }

jq -n --arg location "$AZURE_LOCATION" --arg admin "$VPN_ADMIN_OBJECT_ID" \
  --arg automation "$AUTOMATION_OBJECT_ID" --arg size "$VM_SIZE" \
  --rawfile public "$WORK/admin.pub" --rawfile private "$WORK/admin.key" \
  '{parameters:{
    location:{value:$location}, adminObjectId:{value:$admin}, automationObjectId:{value:$automation},
    vmSize:{value:$size}, sshKey:{value:{publicKey:($public|rtrimstr("\n")),privateKey:$private}}
  }}' > "$WORK/parameters.json"

az deployment sub create --name "vpn-${AZURE_LOCATION}" --location "$AZURE_LOCATION" \
  --template-file "$ROOT/templates/main.bicep" --parameters "@$WORK/parameters.json" \
  --only-show-errors --query properties.outputs -o json > "$WORK/outputs.json"

VM=$(jq -er .vmName.value "$WORK/outputs.json")
az vm get-instance-view --resource-group "$RG" --name "$VM" \
  --query instanceView.extensions -o json > "$WORK/extensions.json"
jq -e '[.[] |
  select(.name == "AADSSHLoginForLinux" or .name == "vpn-bootstrap") |
  select(any(.statuses[]; .code == "ProvisioningState/succeeded"))] | length == 2' \
  "$WORK/extensions.json" > /dev/null ||
  { echo 'VM extensions did not both report successful provisioning.' >&2; exit 1; }
jq -r '.[] | [.name, .statuses[0].code] | @tsv' "$WORK/extensions.json"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  # shellcheck disable=SC2016
  {
    printf '## Regional VPN deployed\n\n'
    printf -- '- Region: `%s`\n- VM size: `%s`\n- Estimated VM cost: %s\n' \
      "$AZURE_LOCATION" "$VM_SIZE" "$COMPUTE_COST"
  } >> "$GITHUB_STEP_SUMMARY"
fi
printf 'Regional VPN deployed in %s: %s. Estimated cost: %s.\n' "$AZURE_LOCATION" "$VM_SIZE" "$COMPUTE_COST"
