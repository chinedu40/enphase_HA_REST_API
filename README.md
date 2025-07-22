
# ⚡ Enphase IQ Battery Integration for Home Assistant (Updated July 2025)

This guide provides a fully automated setup to control **Charge from Grid** and **Discharge to Grid** for Enphase IQ Batteries via the Enlighten API.

It includes:

- 🪪 Automated JWT token retrieval every 12 hours  
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

## 🪪 Step 1 – Automate Enphase JWT Token Retrieval

### 1.1 Create a Shell Script

Save this script as `/config/get_enphase_token.sh`:

```bash
#!/usr/bin/env bash

# 1) Get the login page to capture authenticity_token
TOKEN=$(curl -c /tmp/cookies.txt -L 'https://enlighten.enphaseenergy.com/login'  | sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p')

# 2) Log in with the token, email, and password
curl -b /tmp/cookies.txt -c /tmp/cookies.txt -X POST 'https://enlighten.enphaseenergy.com/login/login'  -H 'Content-Type: application/x-www-form-urlencoded'  --data "utf8=%E2%9C%93&authenticity_token=${TOKEN}&user[email]=YOUR_EMAIL&user[password]=YOUR_PASSWORD"  >/dev/null 2>&1

# 3) Fetch the JWT token
jwt_response=$(curl -b /tmp/cookies.txt 'https://enlighten.enphaseenergy.com/app-api/jwt_token.json' 2>/dev/null)
full_token=$(echo "$jwt_response" | jq -r '.token')

echo "{\"status\":\"OK\",\"token\":\"${full_token}\"}"
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
    scan_interval: 43200  # every 12 hours
    value_template: "{{ value_json.status }}"
    json_attributes:
      - token
```

---

### 1.3 Access the JWT in Home Assistant

After restarting Home Assistant:

- Go to **Developer Tools → States**
- Look for `sensor.enphase_jwt`
- Use `{{ state_attr('sensor.enphase_jwt', 'token') }}` to reference the token in service calls

---

## 🔍 Step 2 – Get `battery_id` and `user_id` from the Enphase Web App

### 2.1 Steps to Capture IDs

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
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
    payload: '{"scheduleType":"dtg"}'

  enphase_validate_cfg:
    url: "https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/battery/sites/{{ battery_id }}/schedules/isValid"
    method: post
    headers:
      content-type: "application/json"
      e-auth-token: "{{ state_attr('sensor.enphase_jwt', 'token') }}"
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
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
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
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
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
    payload: >
      {
        "dtgControl": {
          "enabled": {{ discharge }}
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
      username: "{{ user_id }}"
      origin: "https://battery-profile-ui.enphaseenergy.com"
      referer: "https://battery-profile-ui.enphaseenergy.com/"
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
---

## 🧠 Tips & Troubleshooting

- Avoid hard-coding tokens — use `sensor.enphase_jwt` dynamically
- Always validate before PUT requests
- Tokens expire — ensure your script runs at least every 12 hours
- Use Developer Tools → Services in HA to test your scripts

---
