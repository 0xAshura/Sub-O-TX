#!/usr/bin/env bash
# Sub-O-TX v1.4.2 — AlienVault OTX Domain Recon
# Author: Mihir Limbad (0xAshura)
# Modes: dns (passive DNS unique hosts) | url (paginated url_list unique URLs)
# Docs: OTX domain indicators (passive_dns, url_list), X-OTX-API-KEY header
# https://otx.alienvault.com/assets/static/external_api.html

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# Small professional header
print_header() {
  echo -e "${CYAN}Sub-O-TX v1.4.2${NC} — AlienVault OTX Domain Recon | Author: Mihir Limbad (0xAshura)"
}

# Optional big banner (suppressed if NO_BANNER=1)
big_banner() {
  [[ "${NO_BANNER:-0}" == "1" ]] && return 0
  echo -e "${MAGENTA}"
  cat <<'EOF'
_____       _           _____      _______   __
/  ___|     | |         |  _  |    |_   _\ \ / /
\ `--. _   _| |__ ______| | | |______| |  \ V / 
 `--. \ | | | '_ \______| | | |______| |  /   \ 
/\__/ / |_| | |_) |     \ \_/ /      | | / /^\ \
\____/ \__,_|_.__/       \___/       \_/ \/   \/
                                                
               Sub-O-TX  —  by Mihir Limbad (0xAshura)
EOF
  echo -e "${NC}"
}

usage() {
  print_header
  echo
  echo -e "${BLUE}Synopsis:${NC} ${0##*/} -d <domain>|-f <file> -k <api_key|file> -t <url|dns> [-l <limit>]"
  echo
  echo -e "${BLUE}Options:${NC}"
  printf "  %-22s %s\n" "-d <domain>"          "Single domain to process"
  printf "  %-22s %s\n" "-f <file>"            "File with one domain per line"
  printf "  %-22s %s\n" "-k <key|file>"        "Literal API key or file with keys (rotation)"
  printf "  %-22s %s\n" "-t <url|dns>"         "Mode: url=url_list (paginated), dns=passive_dns (single)"
  printf "  %-22s %s\n" "-l <limit>"           "URL page size (default: 100)"
  echo
  echo -e "${BLUE}Examples:${NC}"
  echo "  ${0##*/} -d example.com -k YOUR_KEY -t dns"
  echo "  ${0##*/} -d example.com -k YOUR_KEY -t url -l 100"
  echo
  exit 1
}

check_dependencies() {
  local deps=("curl" "jq")
  for d in "${deps[@]}"; do
    command -v "$d" >/dev/null 2>&1 || { echo -e "${RED}Missing dependency: $d${NC}"; exit 1; }
  done
}

is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

# Accept literal key or file (one key per non-empty, non-comment line)
load_api_keys() {
  local token_input="$1"; API_KEYS=()
  if [[ -f "$token_input" ]]; then
    while IFS= read -r line; do
      line="${line%%$'\r'}"
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      API_KEYS+=("$line")
    done < "$token_input"
  else
    API_KEYS+=("$token_input")
  fi
  ((${#API_KEYS[@]})) || { echo -e "${RED}No API key(s) loaded from: $token_input${NC}"; exit 1; }
}

http_get() {
  local url="$1" key="$2" out="$3"
  curl -sS -H "X-OTX-API-KEY: $key" -o "$out" -w '%{http_code}' "$url" || echo "000"
}

declare -A KEY_LAST  # per-key last-used timestamp

process_dns_once() {
  local domain="$1"
  big_banner
  local outdir="logs_otx/$domain"; mkdir -p "$outdir"
  local outfile="$outdir/dns_data.txt"; : > "$outfile"

  echo -e "${BLUE}[dns] Domain:${NC} $domain"
  local key="${API_KEYS[0]}"
  local per_key_gap="${PER_KEY_GAP:-3}"

  local now last since
  now=$(date +%s); last="${KEY_LAST[$key]:-0}"; since=$((now-last))
  (( since < per_key_gap )) && sleep $(( per_key_gap - since ))
  KEY_LAST[$key]=$(date +%s)

  local tmp; tmp="$(mktemp)"
  local url="https://otx.alienvault.com/api/v1/indicators/domain/$domain/passive_dns"
  local code; code="$(http_get "$url" "$key" "$tmp")"

  if [[ "$code" != "200" ]]; then
    local err detail
    err="$(jq -r '.error // empty' "$tmp" 2>/dev/null || true)"
    detail="$(jq -r '.detail // empty' "$tmp" 2>/dev/null || true)"
    echo -e "${RED}[ERROR] HTTP $code${NC}"
    [[ -n "$err" ]] && echo -e "${RED}[ERROR] $err${NC}"
    [[ -n "$detail" ]] && echo -e "${RED}[ERROR] $detail${NC}"
    rm -f "$tmp"; return 1
  fi

  jq -r '.passive_dns[]?.hostname' "$tmp" 2>/dev/null | sed '/^null$/d;/^$/d' | sort -u > "$outfile"
  rm -f "$tmp"

  local n; n="$(wc -l < "$outfile" | tr -d ' ')"
  if (( n > 0 )); then
    echo -e "${GREEN}[ok]${NC} $n hosts → ${outfile}"
  else
    echo -e "${YELLOW}[warn]${NC} No data collected for $domain"
  fi
}

process_urls_paged() {
  local domain="$1" limit="$2"
  big_banner
  local outdir="logs_otx/$domain"; mkdir -p "$outdir"
  local outfile="$outdir/url_data.txt"; : > "$outfile"

  echo -e "${BLUE}[url] Domain:${NC} $domain  ${BLUE}limit:${NC} $limit"

  local page=1 key_idx=0
  local success_sleep="${SUCCESS_SLEEP:-1.0}"
  local rate_sleep_fast="${RATE_SLEEP_FAST:-30}"
  local rate_sleep_long="${RATE_SLEEP_LONG:-180}"
  local max_429="${MAX_429_RETRIES:-5}"
  local per_key_gap="${PER_KEY_GAP:-3}"
  local consecutive_429=0

  while :; do
    local url="https://otx.alienvault.com/api/v1/indicators/domain/$domain/url_list?limit=${limit}&page=${page}"
    local key="${API_KEYS[$key_idx]}"; key_idx=$(( (key_idx + 1) % ${#API_KEYS[@]} ))

    local now last since
    now=$(date +%s); last="${KEY_LAST[$key]:-0}"; since=$((now-last))
    (( since < per_key_gap )) && sleep $(( per_key_gap - since ))
    KEY_LAST[$key]=$(date +%s)

    local tmp; tmp="$(mktemp)"
    local code; code="$(http_get "$url" "$key" "$tmp")"

    if [[ "$code" != "200" ]]; then
      local err detail
      err="$(jq -r '.error // empty' "$tmp" 2>/dev/null || true)"
      detail="$(jq -r '.detail // empty' "$tmp" 2>/dev/null || true)"
      if [[ "$code" == "429" ]]; then
        ((consecutive_429++))
        if (( consecutive_429 >= max_429 )); then
          echo -e "${YELLOW}[rate] 429 x${consecutive_429} — cooling ${rate_sleep_long}s${NC}"
          sleep "$rate_sleep_long"; consecutive_429=0
        else
          echo -e "${YELLOW}[rate] 429 — cooling ${rate_sleep_fast}s${NC}"
          sleep "$rate_sleep_fast"
        fi
        rm -f "$tmp"; continue
      fi
      echo -e "${RED}[ERROR] HTTP $code on page $page${NC}"
      [[ -n "$err" ]] && echo -e "${RED}[ERROR] $err${NC}"
      [[ -n "$detail" ]] && echo -e "${RED}[ERROR] $detail${NC}"
      rm -f "$tmp"; break
    fi

    sleep "$success_sleep"
    local data; data="$(jq -r '.url_list[]?.url' "$tmp" 2>/dev/null | sed '/^null$/d;/^$/d' || true)"
    rm -f "$tmp"

    [[ -z "$data" ]] && { echo -e "${GREEN}[done]${NC} No more pages"; break; }
    local n; n="$(wc -l <<< "$data" | tr -d ' ')"
    echo "$data" >> "$outfile"
    echo -e "${GREEN}[page ${page}]${NC} ${n} urls"
    page=$((page + 1))
  done

  if [[ -s "$outfile" ]]; then
    sort -u "$outfile" -o "$outfile"
    local n; n="$(wc -l < "$outfile" | tr -d ' ')"
    echo -e "${GREEN}[ok]${NC} ${n} unique urls → ${outfile}"
  else
    echo -e "${YELLOW}[warn]${NC} No URLs collected for $domain"
  fi
}

# ---- Main ----
check_dependencies

domain=""; file=""; api_param=""; data_type=""; page_limit="${PAGE_LIMIT:-100}"

while getopts ":d:f:k:t:l:" opt; do
  case "$opt" in
    d) domain="$OPTARG" ;;
    f) file="$OPTARG" ;;
    k) api_param="$OPTARG" ;;
    t) data_type="$OPTARG" ;;
    l) page_limit="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "${api_param}" || -z "${data_type}" ]] && usage
[[ "$data_type" != "url" && "$data_type" != "dns" ]] && { echo -e "${RED}-t must be url or dns${NC}"; usage; }

# Load key(s)
API_KEYS=()
load_api_keys "$api_param"

if [[ -n "$domain" ]]; then
  is_valid_domain "$domain" || { echo -e "${RED}Invalid domain: $domain${NC}"; exit 1; }
  print_header
  if [[ "$data_type" == "dns" ]]; then
    process_dns_once "$domain"
  else
    process_urls_paged "$domain" "$page_limit"
  fi
elif [[ -n "$file" ]]; then
  [[ -f "$file" ]] || { echo -e "${RED}File not found: $file${NC}"; exit 1; }
  print_header
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    is_valid_domain "$d" || { echo -e "${YELLOW}[skip] Invalid domain: $d${NC}"; continue; }
    if [[ "$data_type" == "dns" ]]; then
      process_dns_once "$d"
    else
      process_urls_paged "$d" "$page_limit"
    fi
  done < "$file"
else
  usage
fi
