


#!/usr/bin/env bash
set -euo pipefail

EMAIL="YOUR EMAIIL ADDRESS" # <-- set yours
PASSWORD="YOUR PASSWORD" # <-- set yours
BATTERY_ID="YOUR BATTERY ID"   # <-- set yours
USER_ID="YOUR USER ID"      # <-- set yours

COOKIES="/config/cookies.txt"
HDRS="/config/headers.txt"

: > "$COOKIES"
: > "$HDRS"

# 1) Get authenticity_token (and seed cookies)
auth_token=$(curl -sSL -c "$COOKIES" 'https://enlighten.enphaseenergy.com/login' \
  | sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p')

# 2) Login (keeps same cookie jar)
curl -sS -b "$COOKIES" -c "$COOKIES" \
  -X POST 'https://enlighten.enphaseenergy.com/login/login' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data "utf8=%E2%9C%93&authenticity_token=${auth_token}&user[email]=${EMAIL}&user[password]=${PASSWORD}" \
  >/dev/null

# 3) Get JWT (continues same cookies)
jwt_json=$(curl -sS -b "$COOKIES" -c "$COOKIES" \
  'https://enlighten.enphaseenergy.com/app-api/jwt_token.json')
jwt_token=$(echo "$jwt_json" | jq -r '.token // empty')

# 4) Prime BP-XSRF-Token by posting to schedules/isValid (403 is OK; we want Set-Cookie)
#    IMPORTANT: include Origin/Referer + e-auth-token + username
curl -sS -D "$HDRS" -b "$COOKIES" -c "$COOKIES" \
  'https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/'"$BATTERY_ID"'/schedules/isValid' \
  -H 'content-type: application/json' \
  -H 'origin: https://battery-profile-ui.enphaseenergy.com' \
  -H 'referer: https://battery-profile-ui.enphaseenergy.com/' \
  -H "e-auth-token: ${jwt_token}" \
  -H "username: ${USER_ID}" \
  --data-raw '{"scheduleType":"dtg"}' >/dev/null || true

# 5) Extract BP-XSRF-Token from cookies; if missing, fall back to response headers
xsrf_token=$(awk '$6 == "BP-XSRF-Token" { print $7 }' "$COOKIES" | tail -n1 || true)
if [ -z "${xsrf_token:-}" ]; then
  xsrf_token=$(grep -i 'Set-Cookie: *BP-XSRF-Token=' "$HDRS" \
    | sed -E 's/.*BP-XSRF-Token=([^;]+).*/\1/' | tail -n1 || true)
fi

status="OK"
if [ -z "${jwt_token:-}" ] || [ -z "${xsrf_token:-}" ]; then
  status="PARTIAL"
fi

echo "{\"status\":\"${status}\",\"token\":\"${jwt_token}\",\"xsrf\":\"${xsrf_token}\"}"
