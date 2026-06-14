#!/usr/bin/env bash
# get_enphase_schedules_json.sh
# Fetch Enphase schedule IDs (CFG, DTG, RBD) and output as JSON for Home Assistant.
#
# Expects these environment variables (set by the "Enphase Schedules" command_line sensor):
#   ENPHASE_AUTH    - JWT             ({{ state_attr('sensor.enphase_jwt','token') }})
#   ENPHASE_XSRF    - XSRF token      ({{ state_attr('sensor.enphase_jwt','xsrf') }})
#   ENPHASE_COOKIE  - full cookie jar ({{ state_attr('sensor.enphase_jwt','cookie') }})
#
# The battery API authenticates off the full Enlighten session cookie jar; without
# it the /schedules call returns 401.

set -uo pipefail  # tolerate curl/jq failures but catch unset vars

SITE_ID="YOUR_SITE_ID"
USERNAME="YOUR_USER_ID"
LOG_FILE="/config/enphase_debug.log"

{
  echo
  echo "========== $(date '+%F %T') =========="
  echo "Script started"
  echo "AUTH length: ${#ENPHASE_AUTH}, XSRF: ${ENPHASE_XSRF:-missing}, COOKIE: $([ -n "${ENPHASE_COOKIE:-}" ] && echo present || echo missing)"
} >> "$LOG_FILE"

# --- Validate tokens ---
if [[ -z "${ENPHASE_AUTH:-}" || -z "${ENPHASE_XSRF:-}" || -z "${ENPHASE_COOKIE:-}" ]]; then
  echo '{"error":"Missing or empty tokens"}'
  echo "Missing or empty tokens" >> "$LOG_FILE"
  exit 0
fi

BASE_URL="https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/${SITE_ID}"

COMMON_HEADERS=(
  -H "accept: application/json, text/plain, */*"
  -H "content-type: application/json"
  -H "origin: https://battery-profile-ui.enphaseenergy.com"
  -H "referer: https://battery-profile-ui.enphaseenergy.com/"
  -H "username: ${USERNAME}"
  -H "x-xsrf-token: ${ENPHASE_XSRF}"
  -H "e-auth-token: ${ENPHASE_AUTH}"
  -H "cookie: ${ENPHASE_COOKIE}"
)

# --- Fetch data ---
JSON=$(curl -sS "${BASE_URL}/schedules" "${COMMON_HEADERS[@]}" 2>>"$LOG_FILE" || echo "")
echo "Raw response length: ${#JSON}" >> "$LOG_FILE"

if [[ -z "$JSON" ]]; then
  echo '{"error":"Empty response from API"}'
  echo "Empty API response" >> "$LOG_FILE"
  exit 0
fi

# --- Validate JSON ---
if ! echo "$JSON" | jq empty >/dev/null 2>&1; then
  SHORT=$(echo "$JSON" | head -c 200 | sed 's/"/\\"/g')
  echo "{\"error\":\"Invalid or non-JSON response\",\"preview\":\"${SHORT}...\"}"
  echo "Invalid JSON: ${SHORT}" >> "$LOG_FILE"
  exit 0
fi

# --- Extract schedule IDs properly ---
OUTPUT=$(echo "$JSON" | jq -c '
{
  cfg: (
    (.cfg.details // []) |
    map({
      id: .scheduleId,
      start: .startTime,
      end: .endTime,
      limit: .limit,
      days: .days,
      enabled: .isEnabled
    })
  ),
  dtg: (
    (.dtg.details // []) |
    map({
      id: .scheduleId,
      start: .startTime,
      end: .endTime,
      limit: .limit,
      days: .days,
      enabled: .isEnabled
    })
  ),
  rbd: (
    (.rbd.details // []) |
    map({
      id: .scheduleId,
      start: .startTime,
      end: .endTime,
      limit: .limit,
      days: .days,
      enabled: .isEnabled
    })
  ),
  other: []
}
')

echo "$OUTPUT"
echo "Output: $OUTPUT" >> "$LOG_FILE"

exit 0
