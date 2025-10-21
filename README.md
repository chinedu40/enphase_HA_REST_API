
# ⚡ Enphase IQ Battery Integration for Home Assistant (Updated September 2025)

This guide provides a fully automated setup to control **Charge from Grid** and **Discharge to Grid** for Enphase IQ Batteries via the Enlighten API.

It includes:

- 🪪 Automated JWT and XSRF token retrieval every 15 minutes
- 🔍 Instructions to capture your battery and user IDs  
- 🔄 Home Assistant configuration for charge/discharge toggles  
- 🧪 Required validation before toggling  

---

## 📌 Prerequisites

- Home Assistant (core or supervised)
- Your Enphase Enlighten login
- Basic knowledge of YAML and bash
- Installed packages: `curl`, `jq` (for token script)

---

## 🔍 Step 1 – Get `battery_id` and `user_id` from the Enphase Web App

### 1.1 Steps to Capture IDs

1. Log in to [https://enlighten.enphaseenergy.com](https://enlighten.enphaseenergy.com)
2. Open Chrome DevTools → Network tab
3. Navigate to **Battery Settings**, then toggle a setting (e.g., Charge from Grid)
4. In DevTools, find a request URL like:

```
https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/batterySettings/<BATTERY_ID>?userId=<USER_ID>
```

5. Extract from URL:

- `<BATTERY_ID>` → e.g., `1234567`
- `<USER_ID>` → e.g., `9876543`

---

## 🪪 Step 2 – Automate Enphase JWT Token Retrieval

### 2.1 Create a Shell Script

Save this script as `/config/get_enphase_token.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

EMAIL="YOUR_EMAIL"
PASSWORD="YOUR_PASSWORD"
BATTERY_ID=""   # <-- set yours
USER_ID=""      # <-- set yours

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
```

Make it executable:

```bash
chmod +x /config/get_enphase_token.sh
```

---

### 2.2 Add the Token Sensor to `configuration.yaml`

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
```

---

### 2.3 Access the JWT in Home Assistant

After restarting Home Assistant:

- Go to **Developer Tools → States**
- Look for `sensor.enphase_jwt`
- Use `{{ state_attr('sensor.enphase_jwt', 'token') }}` and `{{ state_attr('sensor.enphase_jwt', 'xsrf') }}` to reference the token in service calls

---


## 🧪 Step 3 – Validation Rest Commands (Required!)

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

## 🔁 Step 4 – Rest Commands to Toggle Charging/Discharging

### 4.1 Charge from Grid

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
        "acceptedItcDisclaimer": true
      }
```

### 4.2 Discharge to Grid

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

### 4.3 Restrict Battery Discharge

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

## ▶️ Step 5 – Scripts to Toggle Charging and Discharging

### 5.1 Toggle Charge from Grid

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

### 5.2 Toggle Discharge to Grid

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
### 5.3 Restrict Battery Discharge - On

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
## ▶️ Step 6 – Scheduling

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
        "limit": 100,
        "scheduleType": "{{ schedule_type }}",
        "days": [ {% for d in days %}{{ d | int }}{% if not loop.last %}, {% endif %}{% endfor %} ]
      }
```
Then restart Home Assistant or reload the YAML config.

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
      limit: 100
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
mode: single
icon: mdi:battery-clock

```

# 7 🗑️ Enphase Battery — Delete Schedules from Home Assistant (REST Method)

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
        cfg_ids: "{{ state_attr('sensor.enphase_schedules', 'cfg') or [] }}"
        dtg_ids: "{{ state_attr('sensor.enphase_schedules', 'dtg') or [] }}"
        rbd_ids: "{{ state_attr('sensor.enphase_schedules', 'rbd') or [] }}"
    - choose:
        - conditions: "{{ schedule_type in ['cfg', 'all'] }}"
          sequence:
            - repeat:
                for_each: "{{ cfg_ids }}"
                sequence:
                  - service: rest_command.enphase_delete_schedule
                    data:
                      battery_id: "{{ battery_id }}"
                      user_id: "{{ user_id }}"
                      schedule_id: "{{ repeat.item }}"
            - delay: "00:00:02"
        - conditions: "{{ schedule_type in ['dtg', 'all'] }}"
          sequence:
            - repeat:
                for_each: "{{ dtg_ids }}"
                sequence:
                  - service: rest_command.enphase_delete_schedule
                    data:
                      battery_id: "{{ battery_id }}"
                      user_id: "{{ user_id }}"
                      schedule_id: "{{ repeat.item }}"
            - delay: "00:00:02"
        - conditions: "{{ schedule_type in ['rbd', 'all'] }}"
          sequence:
            - repeat:
                for_each: "{{ rbd_ids }}"
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
