
# ⚡ Enphase IQ Battery Integration for Home Assistant (Updated January 2026)

This guide provides a fully automated setup to control **Charge from Grid** and **Discharge to Grid** for Enphase IQ Batteries via the Enlighten API.

It includes:

- 🪪 Automated JWT and XSRF token retrieval every 15 minutes 
- 🔄 Home Assistant configuration for charge/discharge toggles  
- 🧪 Required validation before toggling  

## NOTES - June 2026
1. **401 Unauthorized fix** – Enphase's battery API now authenticates off the **full Enlighten session cookie jar** (the Rails session cookie, `enlighten_manager_token_production`, `BP-XSRF-Token`, …), not just the `e-auth-token` JWT. Sending only the JWT — or just one or two cookies — returns 401. The token script now emits the entire cookie jar as a single `cookie` attribute, and every `rest_command` replays it in the `Cookie` header. If you were getting 401s, re-copy the updated `get_enphase_token.sh` and the `rest_command` blocks below.
2. **Automatic session refresh** – the homeowner JWT can stay valid for days while the session cookies expire sooner. On each run `get_enphase_token.sh` now probes the battery API (the `isValid` call it already makes for the XSRF token); if the session has expired (401/403) it automatically does a fresh login to mint a new cookie jar. Set the JWT sensor's `scan_interval` to `900` (15 min) so this self-heal runs often enough to keep the `cookie` attribute live.
3. **`Timeout for command` fix** – HA's `command_line` integration kills any command running longer than `command_timeout` (default **15 s**). The login/refresh path makes several `curl` calls, so a slow Enphase response could exceed that. Every `curl` now uses `--connect-timeout 8 --max-time 20` (fails fast instead of hanging) and the `command_line` sensors set `command_timeout: 60` for headroom.

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

Copy the canonical script from this repo: **[`samples/get_enphase_token.sh`](samples/get_enphase_token.sh)** → save it as `/config/get_enphase_token.sh` and set your `EMAIL` / `PASSWORD` at the top (battery & user IDs auto-discover). It logs in, refreshes the JWT + the full Enlighten cookie jar, self-heals an expired session, and prints a JSON line (`status/token/xsrf/cookie/exp/user_id/battery_id`) that the sensor below consumes.

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
    command_timeout: 60  # allow time for the full login + session-refresh path
    scan_interval: 900  # every 15 minutes
    value_template: "{{ value_json.status }}"
    json_attributes:
      - token
      - xsrf
      - cookie
      - exp
      - battery_id
      - user_id
```

---

### 1.3 Access the JWT in Home Assistant

After restarting Home Assistant:

- Go to **Developer Tools → States**
- Look for `sensor.enphase_jwt`
- Use `{{ state_attr('sensor.enphase_jwt', 'token') }}` and `{{ state_attr('sensor.enphase_jwt', 'xsrf') }}` to reference the token in service calls

---


## 🧪 Step 2 – Validation Rest Commands (Required!)

> The complete, always-current `rest_command:` and `command_line:` config lives in **[`samples/configuration.yaml`](samples/configuration.yaml)** — copy from there. It defines the shared battery-API headers once via a YAML anchor (`&enphase_headers`) and reuses them with `*enphase_headers`. The blocks below are illustrative excerpts (headers shown expanded for clarity).

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
      cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
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
      cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
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
      cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
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
      cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
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
      cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
    payload: >
      {
        "rbdControl": {
          "enabled": {{ restrict }}
        }
      }
```

---

## ▶️ Step 4 – Scripts to Toggle Charging and Discharging

### 4.0 Refresh-session helper (avoids a one-off 401)

The token sensor self-heals every 15 minutes (Step 1), but a command fired in the gap
*right after* a session dies could still 401 once. This reusable script forces the
sensor to re-run (which probes the battery API and re-logs in if needed) and waits for
a fresh, healthy result. Call `script.enphase_refresh_session` as the first step of any
battery command to close that gap.

```yaml
enphase_refresh_session:
  alias: Enphase – Refresh Session
  description: >-
    Force the Enphase token sensor to re-run so it probes the battery API and, if the
    session has expired, logs in again to mint a fresh cookie jar. Call this before a
    battery rest_command so a session that died between the sensor's scans can't cause
    a one-off 401.
  mode: single
  sequence:
    - variables:
        t0: "{{ now().timestamp() }}"
    - action: homeassistant.update_entity
      target:
        entity_id: sensor.enphase_jwt
    # The cookie attribute changes every run, so last_updated advances once the refresh
    # completes. Wait for a NEW, healthy result before returning.
    - wait_template: >-
        {{ states.sensor.enphase_jwt.last_updated.timestamp() > t0
           and states('sensor.enphase_jwt') == 'OK' }}
      timeout: "00:00:25"
      continue_on_timeout: true
```

> Calling `script.enphase_refresh_session` from another script blocks until it finishes,
> so the command below only runs once a fresh session is confirmed.

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
    - service: script.enphase_refresh_session
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
    - service: script.enphase_refresh_session
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
  battery_id: "YOUR_BATTERY_ID"
  user_id: "YOUR_USER_ID"
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
      cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
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

Copy the canonical script from this repo: **[`samples/get_enphase_schedules_json.sh`](samples/get_enphase_schedules_json.sh)** → `/config/get_enphase_schedules_json.sh`, and set `SITE_ID` / `USERNAME` at the top. It reads `ENPHASE_AUTH` / `ENPHASE_XSRF` / `ENPHASE_COOKIE` (passed by the sensor), calls the battery `/schedules` endpoint, and emits the CFG/DTG/RBD schedule objects as JSON.

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
        ENPHASE_COOKIE="{{ state_attr("sensor.enphase_jwt", "cookie") }}"
        /config/get_enphase_schedules_json.sh'
      command_timeout: 60
      scan_interval: 30
      value_template: "OK"
      json_attributes:
        - cfg
        - dtg
        - rbd
        - other
```
After reloading, check Developer Tools → States → sensor.enphase_schedules.
You should see arrays of schedule objects (id, start, end, limit, days, enabled) under cfg, dtg, rbd.

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
      Cookie: "{{ state_attr('sensor.enphase_jwt', 'cookie') }}"
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
