
# ⚡ Enphase IQ Battery Integration for Home Assistant (Updated January 2026)

This guide provides a fully automated setup to control **Charge from Grid** and **Discharge to Grid** for Enphase IQ Batteries via the Enlighten API.

It includes:

- 🪪 Automated JWT and XSRF token retrieval every 15 minutes 
- 🔄 Home Assistant configuration for charge/discharge toggles  
- 🧪 Required validation before toggling  

## NOTES - January 2026
1. Update script to automatically fetch battery ID and User ID

October 2025 

1. When creating an automation or script in home assistant to turn off cfg, dtg, rbd, making sure you toggle first, then 2 or 3 seconds later, delete the schedule if needed. 

---

## 📌 Prerequisites

- Home Assistant (core or supervised)
- Your Enphase Enlighten login
- Basic knowledge of YAML and bash
- Installed packages: `curl`, `jq` (for token script)

---

## 🔍 Step 1 – – Automate Enphase JWT Token Retrieval

### 1.1 Create a Shell Script

Save this script as `/config/get_enphase_token.sh` and make sure you fill in your details at the top of the script:

```#!/usr/bin/env bash
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
```

Make it executable:

```bash
chmod +x /config/get_enphase_token.sh
```

---

### 1.2 Add the Token Sensor to `configuration.yaml`

```yaml
sensor:
  - platform: command_line
    name: "Enphase JWT"
    command: "bash /config/get_enphase_token.sh"
    scan_interval: 900  # every 15 minutes
    value_template: "{{ value_json.status }}"
    json_attributes:
      - token
      - xsrf
      - exp
```

---

### 1.3 Access the JWT in Home Assistant

After restarting Home Assistant:

- Go to **Developer Tools → States**
- Look for `sensor.enphase_jwt`
- Use `{{ state_attr('sensor.enphase_jwt', 'token') }}` and `{{ state_attr('sensor.enphase_jwt', 'xsrf') }}` to reference the token in service calls

---


## 🧪 Step 2 – Validation Rest Commands (Required!)

These commands must run before toggling battery settings or the PUT requests will silently fail.

```yaml
rest_command:
  enphase_validate_dtg:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/{{ battery_id }}/schedules/isValid"
    method: post
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      x-xsrf-token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
      cookie: "BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
    payload: '{"scheduleType":"dtg"}'

  enphase_validate_cfg:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/{{ battery_id }}/schedules/isValid"
    method: post
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      x-xsrf-token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
      cookie: "BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
    payload: '{"scheduleType":"cfg","forceScheduleOpted":true}'
```

---

## 🔁 Step 3 – Rest Commands to Toggle Charging/Discharging

### 3.1 Charge from Grid

```yaml
  enphase_battery_charge_from_grid:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/batterySettings/{{ battery_id }}?userId={{ user_id }}&source=enho"
    method: put
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      x-xsrf-token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
      cookie: "BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
    payload: >
      {
        "chargeFromGrid": {{ charge }},
        "acceptedItcDisclaimer": "{{ now().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] ~ 'Z' }}"
      }
```

### 3.2 Discharge to Grid

```yaml
  enphase_battery_discharge_to_grid:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/batterySettings/{{ battery_id }}?userId={{ user_id }}&source=enho"
    method: put
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      x-xsrf-token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
      cookie: "BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
    payload: >
      {
        "dtgControl": {
          "enabled": {{ discharge }}
        }
      }
```

### 3.3 Restrict Battery Discharge

```yaml
  enphase_battery_restrict_discharge:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/batterySettings/{{ battery_id }}?userId={{ user_id }}&source=enho"
    method: put
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      x-xsrf-token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
      cookie: "BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
    payload: >
      {
        "rbdControl": {
          "enabled": {{ restrict }}
        }
      }
```

---

## ▶️ Step 4 – Scripts to Toggle Charging and Discharging

### 4.1 Toggle Charge from Grid

```yaml
toggle_enphase_charge_from_grid:
  alias: Toggle Enphase Charge from Grid
  description: Enable or disable Charge from Grid mode
  fields:
    charge:
      description: true to enable, false to disable
      example: true
  sequence:
    - service: rest_command.enphase_validate_cfg
    - delay: "00:00:01"
    - service: rest_command.enphase_battery_charge_from_grid
      data:
        charge: "{{ charge }}"
  mode: single
```

---

### 4.2 Toggle Discharge to Grid

```yaml
toggle_enphase_discharge_to_grid:
  alias: Toggle Enphase Discharge to Grid
  description: Enable or disable Discharge to Grid mode
  fields:
    discharge:
      description: true to enable, false to disable
      example: true
  sequence:
    - service: rest_command.enphase_validate_dtg
    - delay: "00:00:01"
    - service: rest_command.enphase_battery_discharge_to_grid
      data:
        discharge: "{{ discharge }}"
  mode: single
```
### 4.3 Restrict Battery Discharge - On

```yaml
action: rest_command.enphase_battery_restrict_discharge
data:
  battery_id: "5652514"
  user_id: "4980363"
  restrict: "true"
response_variable: enphase
```
Change restrict to false to turn it off. 

---

## ✅ Example Automation

```yaml
automation:
  - alias: Enable Charge from Grid at 02:00
    trigger:
      - platform: time
        at: "02:00:00"
    action:
      - service: script.toggle_enphase_charge_from_grid
        data:
          charge: true
```

---
## ▶️ Step 5 – Scheduling

---

## 🧩 Setup Instructions

### 1. Add to `configuration.yaml`

Paste the following under your `rest_command:` section:

```yaml
rest_command:
  enphase_add_schedule:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/{{ battery_id }}/schedules"
    method: post
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      x-xsrf-token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
      cookie: "BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
    payload: >
      {
        "timezone": "Europe/London",
        "startTime": "{{ start_time[:5] }}",
        "endTime": "{{ end_time[:5] }}",
        "limit": {{ limit }},
        "scheduleType": "{{ schedule_type }}",
        "days": [ {% for d in days %}{{ d | int }}{% if not loop.last %}, {% endif %}{% endfor %} ]
      }
```
Then restart Home Assistant or reload the YAML config.
NOTE: setting the limit is important depending on if adding a schedule for charging or discharging as it will stop at the limit set. When it reaches the limit it will run from grid/Solar
## 2. Add Script in the UI (Scripts Editor)

Go to Settings → Automations & Scenes → Scripts → + Add Script
Then paste the following:

```yaml
alias: Add Enphase Battery Schedule
sequence:
  - service: rest_command.enphase_add_schedule
    data:
      start_time: "{{ start_time }}"
      end_time: "{{ end_time }}"
      schedule_type: "{{ schedule_type }}"
      days: "{{ days }}"
      user_id: "{{ user_id }}"
      battery_id: "{{ battery_id }}"
      limit: {{ limit }}
fields:
  start_time:
    description: "Start time (e.g. '02:00')"
    example: "02:00"
  end_time:
    description: "End time (e.g. '03:00')"
    example: "03:00"
  schedule_type:
    description: "Type of schedule: CFG (charge), DTG (discharge to grid), RBD (reserve battery discharge)"
    selector:
      select:
        options:
          - CFG
          - DTG
          - RBD
  days:
    description: "Select days to apply schedule (Mon=1 to Sun=7)"
    selector:
      select:
        multiple: true
        mode: list
        options:
          - label: Monday
            value: "1"
          - label: Tuesday
            value: "2"
          - label: Wednesday
            value: "3"
          - label: Thursday
            value: "4"
          - label: Friday
            value: "5"
          - label: Saturday
            value: "6"
          - label: Sunday
            value: "7"
  user_id:
    description: "User ID (default: 1234567)"
    default: 1234567
  battery_id:
    description: "Battery ID (default: 1234567)"
    default: 1234567
  limit:
    description: " Charge/Discharge limit"
    selector:
      number:
        min: 6
        max: 100
        mode: box
        step: 1
    default: 100 #set 100 if charging or 6 if discharging 
mode: single
icon: mdi:battery-clock

```

# 6 🗑️ Enphase Battery — Delete Schedules from Home Assistant (REST Method)

This guide lets you **list and delete Enphase schedules** (CFG / DTG / RBD) inside **Home Assistant** using a command_line sensor and a **REST command** that mirrors the browser request.

> Works nicely with Predbat: clear out overlapping schedules and re-apply your desired state.

---

## 1) Create the “get schedules” script

**File:** `/config/get_enphase_schedules_json.sh`

```bash
#!/usr/bin/env bash
# Fetch Enphase schedule IDs grouped by type (CFG/DTG/RBD) for Home Assistant.
# Uses ENPHASE_AUTH (JWT) and ENPHASE_XSRF (xsrf) environment variables.

set -uo pipefail

SITE_ID="YOUR_SITE_ID"
USERNAME="YOUR_USER_ID"
LOG_FILE="/config/enphase_debug.log"

{
  echo
  echo "========== $(date '+%F %T') =========="
  echo "Script started"
  echo "AUTH present: $([ -n "${ENPHASE_AUTH:-}" ] && echo yes || echo no), XSRF: ${ENPHASE_XSRF:-missing}"
} >> "$LOG_FILE"

if [[ -z "${ENPHASE_AUTH:-}" || -z "${ENPHASE_XSRF:-}" ]]; then
  echo '{"error":"Missing or empty tokens"}'
  echo "Missing or empty tokens" >> "$LOG_FILE"
  exit 0
fi

BASE_URL="https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/${SITE_ID}"

JSON=$(curl -sS "${BASE_URL}/schedules" \
  -H "accept: application/json, text/plain, */*" \
  -H "content-type: application/json" \
  -H "origin: https://battery-profile-ui.enphaseenergy.com" \
  -H "referer: https://battery-profile-ui.enphaseenergy.com/" \
  -H "username: ${USERNAME}" \
  -H "x-xsrf-token: ${ENPHASE_XSRF}" \
  -H "e-auth-token: ${ENPHASE_AUTH}" 2>>"$LOG_FILE" || echo "")

echo "Raw response length: ${#JSON}" >> "$LOG_FILE"

if [[ -z "$JSON" ]]; then
  echo '{"error":"Empty response from API"}'
  echo "Empty API response" >> "$LOG_FILE"
  exit 0
fi

if ! echo "$JSON" | jq empty >/dev/null 2>&1; then
  SHORT=$(echo "$JSON" | head -c 200 | sed 's/"/\\"/g')
  echo "{\"error\":\"Invalid or non-JSON response\",\"preview\":\"${SHORT}...\"}"
  echo "Invalid JSON: ${SHORT}" >> "$LOG_FILE"
  exit 0
fi

OUTPUT=$(echo "$JSON" | jq -c '{
  cfg: (.cfg.details // [] | map(.scheduleId)),
  dtg: (.dtg.details // [] | map(.scheduleId)),
  rbd: (.rbd.details // [] | map(.scheduleId)),
  other: []
}')

echo "$OUTPUT"
echo "Output: $OUTPUT" >> "$LOG_FILE"
exit 0
```

Make it executable:

```chmod +x /config/get_enphase_schedules_json.sh```


⸻

2) Create the command_line sensor

configuration.yaml (or split file):
```yaml
command_line:
  - sensor:
      name: "Enphase Schedules"
      command: >
        /bin/bash -c 'ENPHASE_AUTH="{{ state_attr("sensor.enphase_jwt", "token") }}"
        ENPHASE_XSRF="{{ state_attr("sensor.enphase_jwt", "xsrf") }}"
        /config/get_enphase_schedules_json.sh'
      scan_interval: 30
      value_template: "OK"
      json_attributes:
        - cfg
        - dtg
        - rbd
        - other
```
After reloading, check Developer Tools → States → sensor.enphase_schedules.
You should see arrays of schedule IDs under cfg, dtg, rbd.

⸻

3) Create the REST command (delete by ID)

configuration.yaml:
```yaml
rest_command:
  enphase_delete_schedule:
    url: >-
      https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/{{ battery_id }}/schedules/{{ schedule_id }}/delete
    method: POST
    headers:
      Accept: "application/json, text/plain, */*"
      Content-Type: "application/json"
      Origin: "https://battery-profile-ui.enphaseenergy.com"
      Referer: "https://battery-profile-ui.enphaseenergy.com/"
      Username: "{{ user_id }}"
      X-XSRF-Token: "{{ state_attr('sensor.enphase_jwt', 'xsrf') }}"
      Cookie: "locale=en; BP-XSRF-Token={{ state_attr('sensor.enphase_jwt', 'xsrf') }};"
      E-Auth-Token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      User-Agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"
      Connection: "close"
      TE: "trailers"
    payload: "{}"
    content_type: "application/json"
```
Test it in Developer Tools → Services:
```
service: rest_command.enphase_delete_schedule
data:
  schedule_id: XXXX-XXXX-XXX-XXX
```
Expected response: {"message":"success"}
If you see 403, wait for sensor.enphase_jwt to refresh or add a short delay before calling.

⸻

4) Create the user-selectable script (cfg / dtg / rbd / all)

scripts.yaml:
```
  alias: "Delete Enphase Schedules by Type"
  mode: single
  fields:
    schedule_type:
      name: "Schedule Type"
      description: "Select which schedule(s) to delete"
      required: true
      selector:
        select:
          options:
            - cfg
            - dtg
            - rbd
            - all
    battery_id:
      name: "Battery ID"
      description: "Your Enphase Site/Battery ID"
      required: true
    user_id:
      name: "User ID"
      description: "Your Enphase User ID"
      required: true
  sequence:
    - variables:
        schedules:
          cfg: "{{ state_attr('sensor.enphase_schedules', 'cfg') or [] }}"
          dtg: "{{ state_attr('sensor.enphase_schedules', 'dtg') or [] }}"
          rbd: "{{ state_attr('sensor.enphase_schedules', 'rbd') or [] }}"
        types_to_delete: >
          {% if schedule_type == 'all' %}
            ['cfg','dtg','rbd']
          {% else %}
            [schedule_type]
          {% endif %}
    - repeat:
        for_each: "{{ types_to_delete }}"
        sequence:
          - repeat:
              for_each: "{{ schedules[repeat.item] }}"
              sequence:
                - service: rest_command.enphase_delete_schedule
                  data:
                    battery_id: "{{ battery_id }}"
                    user_id: "{{ user_id }}"
                    schedule_id: "{{ repeat.item }}"
          - delay: "00:00:02"
    - service: homeassistant.update_entity
      target:
        entity_id: sensor.enphase_schedules
```
Usage examples
	•	Call the script from the Services UI with schedule_type: dtg
	•	Or add a Dashboard button that invokes the script with a chosen type.

---

## 🧠 Tips & Troubleshooting

- Avoid hard-coding tokens — use `sensor.enphase_jwt` dynamically
- Always validate before PUT requests
- Tokens expire — ensure your script runs at least every 15 minutes
- Use Developer Tools → Services in HA to test your scripts

---
