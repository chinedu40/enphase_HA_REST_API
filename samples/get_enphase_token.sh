#!/usr/bin/env bash
set -euo pipefail

EMAIL="YOUR EMAIL ADDRESS" # <--- ENTER YOURS HERE
PASSWORD="YOUR PASSWORD" # <--- ENTER YOURS HERE
BATTERY_ID="YOUR BATTERY ID" # <--- ENTER YOURS HERE
USER_ID="YOUR USER ID" # <--- ENTER YOURS HERE

WORKDIR="/config"
COOKIES="$WORKDIR/cookies.txt"
HDRS="$WORKDIR/headers.txt"
JWT_FILE="$WORKDIR/jwt.txt"

# ------------------ functions ------------------

get_jwt() {
  : > "$COOKIES"
  : > "$HDRS"

  auth_token=$(curl -sSL -c "$COOKIES" 'https://enlighten.enphaseenergy.com/login' \
    | sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p')

  curl -sS -b "$COOKIES" -c "$COOKIES" \
    -X POST 'https://enlighten.enphaseenergy.com/login/login' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "utf8=%E2%9C%93&authenticity_token=${auth_token}&user[email]=${EMAIL}&user[password]=${PASSWORD}" \
    >/dev/null

  jwt_json=$(curl -sS -b "$COOKIES" -c "$COOKIES" \
    'https://enlighten.enphaseenergy.com/app-api/jwt_token.json')
  jwt_token=$(echo "$jwt_json" | jq -r '.token // empty')

  echo "$jwt_token" > "$JWT_FILE"
}

jwt_valid() {
  if [[ ! -s "$JWT_FILE" ]]; then
    return 1
  fi
  jwt=$(<"$JWT_FILE")
  payload=$(echo "$jwt" | cut -d. -f2 | base64 -d -i 2>/dev/null || true)
  exp=$(echo "$payload" | jq -r .exp 2>/dev/null || echo 0)
  now=$(date +%s)
  # valid if >1h left
  [[ "$exp" -gt $((now + 3600)) ]]
}

get_xsrf() {
  jwt=$(<"$JWT_FILE")
  curl -sS -D "$HDRS" -b "$COOKIES" -c "$COOKIES" \
    "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/${BATTERY_ID}/schedules/isValid" \
    -H 'content-type: application/json' \
    -H 'origin: https://battery-profile-ui.enphaseenergy.com' \
    -H 'referer: https://battery-profile-ui.enphaseenergy.com/' \
    -H "e-auth-token: ${jwt}" \
    -H "username: ${USER_ID}" \
    --data-raw '{"scheduleType":"dtg"}' >/dev/null || true

  xsrf_token=$(awk '$6 == "BP-XSRF-Token" { print $7 }' "$COOKIES" | tail -n1 || true)
  if [ -z "${xsrf_token:-}" ]; then
    xsrf_token=$(grep -i 'Set-Cookie: *BP-XSRF-Token=' "$HDRS" \
      | sed -E 's/.*BP-XSRF-Token=([^;]+).*/\1/' | tail -n1 || true)
  fi

  echo "$xsrf_token"
}

# ------------------ main ------------------

if ! jwt_valid; then
  get_jwt
fi

jwt=$(<"$JWT_FILE")
xsrf=$(get_xsrf)

# Extract middle part of JWT
payload=$(echo "$jwt" | cut -d. -f2)

# Convert from base64url → base64 (replace -_ with +/ and pad with =)
payload=$(echo "$payload" | tr '_-' '/+' )
pad=$(( (4 - ${#payload} % 4) % 4 ))
payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"

# Decode to JSON and extract exp
exp=$(echo "$payload" | base64 -d 2>/dev/null | jq -r .exp 2>/dev/null || echo 0)

status="OK"
if [ -z "$jwt" ] || [ -z "$xsrf" ]; then
  status="PARTIAL"
fi

echo "{\"status\":\"${status}\",\"token\":\"${jwt}\",\"xsrf\":\"${xsrf}\",\"exp\":${exp}}"
