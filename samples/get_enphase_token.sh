#!/usr/bin/env bash
set -euo pipefail

EMAIL="xxxxxx"     # enlighten email
PASSWORD="xxxxxxx" # enlighten password

# Leave these empty to auto-discover
BATTERY_ID="${BATTERY_ID:-}"
USER_ID="${USER_ID:-}"

WORKDIR="/config"
COOKIES="$WORKDIR/cookies.txt"
HDRS="$WORKDIR/headers.txt"
JWT_FILE="$WORKDIR/jwt.txt"

# ------------------ helpers ------------------

b64url_decode() {
  # base64url -> raw bytes (best-effort)
  local s="${1:-}"
  s="${s//_/\/}"
  s="${s//-/+}"
  local pad=$(( (4 - ${#s} % 4) % 4 ))
  s="${s}$(printf '=%.0s' $(seq 1 "$pad"))"
  printf '%s' "$s" | base64 -d 2>/dev/null || true
}

jwt_payload_json() {
  local jwt="${1:-}"
  local payload
  payload="$(printf '%s' "$jwt" | cut -d. -f2)"
  b64url_decode "$payload"
}

jwt_exp() {
  local jwt="${1:-}"
  local payload
  payload="$(jwt_payload_json "$jwt")"
  printf '%s' "$payload" | jq -r '.exp // 0' 2>/dev/null || echo 0
}

cookies_present() {
  [[ -s "$COOKIES" ]]
}

# Auto-discover numeric site/battery id + numeric user id (your proven HAR method)
discover_ids() {
  local final_url site_id user_id

  # Site/battery id from final post-login URL (supports /web/<id>/..., /pv/systems/<id>/..., /systems/<id>/...)
  final_url="$(
    curl -sS --compressed -L -b "$COOKIES" -c "$COOKIES" \
      -o /dev/null -w "%{url_effective}" \
      "https://enlighten.enphaseenergy.com/"
  )"

  site_id="$(
    printf '%s' "$final_url" \
      | grep -oE "/(web|pv/systems|systems)/[0-9]+" \
      | head -n1 \
      | grep -oE '[0-9]+$' \
      || true
  )"

  if [[ -z "${site_id:-}" || ! "$site_id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not extract site/battery id from final URL: $final_url" >&2
    return 1
  fi

  # Numeric userId from app-api/<site>/data.json
  user_id="$(
    curl -sS --compressed -b "$COOKIES" -c "$COOKIES" \
      "https://enlighten.enphaseenergy.com/app-api/${site_id}/data.json?app=1&device_status=non_retired&is_mobile=0" \
      | jq -r '.app.userId // .app.user_id // .app.user.id // empty' 2>/dev/null \
      || true
  )"

  if [[ -z "${user_id:-}" || ! "$user_id" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not extract numeric userId from app-api/${site_id}/data.json" >&2
    return 1
  fi

  # Populate globals only if not already set
  [[ -n "${BATTERY_ID:-}" ]] || BATTERY_ID="$site_id"
  [[ -n "${USER_ID:-}"   ]] || USER_ID="$user_id"

  return 0
}

# ------------------ functions ------------------

get_jwt_and_login() {
  : > "$COOKIES"
  : > "$HDRS"

  # Fetch authenticity token
  local auth_token
  auth_token="$(
    curl -sS --compressed -c "$COOKIES" 'https://enlighten.enphaseenergy.com/login' \
      | sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p'
  )"

  [[ -n "${auth_token:-}" ]] || { echo "ERROR: authenticity_token not found" >&2; return 1; }

  # Login (creates session cookies)
  curl -sS --compressed -b "$COOKIES" -c "$COOKIES" \
    -X POST 'https://enlighten.enphaseenergy.com/login/login' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "utf8=%E2%9C%93&authenticity_token=${auth_token}&user[email]=${EMAIL}&user[password]=${PASSWORD}" \
    >/dev/null

  # Get JWT
  local jwt_json jwt_token
  jwt_json="$(
    curl -sS --compressed -b "$COOKIES" -c "$COOKIES" \
      'https://enlighten.enphaseenergy.com/app-api/jwt_token.json'
  )"
  jwt_token="$(printf '%s' "$jwt_json" | jq -r '.token // empty')"

  [[ -n "${jwt_token:-}" ]] || { echo "ERROR: JWT token not returned (login failed?)" >&2; return 1; }

  printf '%s' "$jwt_token" > "$JWT_FILE"

  # Discover numeric IDs using the now-authenticated session
  discover_ids
}

jwt_valid() {
  [[ -s "$JWT_FILE" ]] || return 1
  local jwt exp now
  jwt="$(<"$JWT_FILE")"
  exp="$(jwt_exp "$jwt")"
  now="$(date +%s)"
  # valid if >1h left
  [[ "$exp" -gt $((now + 3600)) ]]
}

get_xsrf() {
  local jwt
  jwt="$(<"$JWT_FILE")"

  curl -sS --compressed -D "$HDRS" -b "$COOKIES" -c "$COOKIES" \
    "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/${BATTERY_ID}/schedules/isValid" \
    -H 'content-type: application/json' \
    -H 'origin: https://battery-profile-ui.enphaseenergy.com' \
    -H 'referer: https://battery-profile-ui.enphaseenergy.com/' \
    -H "e-auth-token: ${jwt}" \
    -H "username: ${USER_ID}" \
    --data-raw '{"scheduleType":"dtg"}' >/dev/null || true

  local xsrf_token
  xsrf_token="$(awk '$6 == "BP-XSRF-Token" { print $7 }' "$COOKIES" | tail -n1 || true)"
  if [[ -z "${xsrf_token:-}" ]]; then
    xsrf_token="$(grep -i 'Set-Cookie: *BP-XSRF-Token=' "$HDRS" \
      | sed -E 's/.*BP-XSRF-Token=([^;]+).*/\1/' | tail -n1 || true)"
  fi

  printf '%s' "$xsrf_token"
}

# ------------------ main ------------------

# Ensure we have a valid JWT AND a logged-in cookie jar that lets us discover ids / call battery endpoints
# If any of these are missing, do a fresh login.
need_login=0
jwt_valid || need_login=1
cookies_present || need_login=1
[[ -n "${BATTERY_ID:-}" && -n "${USER_ID:-}" ]] || need_login=1

if [[ "$need_login" -eq 1 ]]; then
  get_jwt_and_login
else
  # Even with valid JWT, auto-fill ids if user left them blank
  [[ -n "${BATTERY_ID:-}" && -n "${USER_ID:-}" ]] || discover_ids
fi

# Hard fail if still missing (you confirmed these must be numeric)
[[ "${BATTERY_ID:-}" =~ ^[0-9]+$ ]] || { echo "ERROR: BATTERY_ID not set / not numeric" >&2; exit 1; }
[[ "${USER_ID:-}"   =~ ^[0-9]+$ ]] || { echo "ERROR: USER_ID not set / not numeric" >&2; exit 1; }

jwt="$(<"$JWT_FILE")"
xsrf="$(get_xsrf)"

exp="$(jwt_exp "$jwt")"

status="OK"
if [[ -z "${jwt:-}" || -z "${xsrf:-}" ]]; then
  status="PARTIAL"
fi

echo "{\"status\":\"${status}\",\"token\":\"${jwt}\",\"xsrf\":\"${xsrf}\",\"exp\":${exp},\"user_id\":${USER_ID},\"battery_id\":${BATTERY_ID}}"
