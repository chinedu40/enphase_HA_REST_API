
#  How to Capture Your battery_id and user_id from the Enphase Web App

The first step is you’ll need your battery_id and user_id from the Enphase web interface. Follow these steps:

## Step-by-Step Guide
	1.	Go to the Enphase Web App
		•	Visit: https://enlighten.enphaseenergy.com/
		•	Log in with your credentials.
	2.	Open Developer Tools
		•	Right-click anywhere on the page → Click “Inspect”
		•	Select the Network tab.
	3.	Trigger a Battery Setting Change
		•	Navigate to your battery settings.
		•	Locate a toggle switch (e.g., “Charge from Grid”) and clear the current network logs in DevTools.
		•	Toggle the setting to ON or OFF to trigger a network request.
	4.	Look for the API Request
		•	In the Network tab, look for a request similar to this:
"https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/batterySettings/<BATTERY_ID>?userId=<USER_ID>"


	5.	Extract the IDs
		•	From the URL, copy the following:
		•	🔋 battery_id → appears in the path after batterySettings/
		•	👤 user_id → appears as the query parameter userId=

✅ Example

URL:
https://enlighten.enphaseenergy.com/service/batteryConfig/api/v1/batterySettings/1234567?userId=9876543

	•	battery_id: 1234567
	•	user_id: 9876543

Use these values in your Home Assistant automation or configuration.



# Automate Enphase JWT Token Retrieval for Home Assistant

To authenticate REST calls to Enphase’s battery API, you need a valid JWT token. This setup will automatically fetch and refresh the token every 12 hours using a Bash script and a command_line sensor.

## 1. Create Bash Script

Create a file called get_enphase_token.sh in your Home Assistant config directory:
```
Path: /config/get_enphase_token.sh
```
Make it executable:
```
chmod +x /config/get_enphase_token.sh
```
Replace YOUR_EMAIL and YOUR_PASSWORD with your actual Enphase login credentials:
```
#!/usr/bin/env bash

# 1) Get the login page to capture authenticity_token

TOKEN=$(curl -c /tmp/cookies.txt -L 'https://enlighten.enphaseenergy.com/login' \
 | sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p')

# 2) Log in with the token, email, and password

curl -b /tmp/cookies.txt -c /tmp/cookies.txt -X POST 'https://enlighten.enphaseenergy.com/login/login' \
 -H 'Content-Type: application/x-www-form-urlencoded' \
 --data "utf8=%E2%9C%93&authenticity_token=${TOKEN}&user[email]=YOUR_EMAIL&user[password]=YOUR_PASSWORD" \
 >/dev/null 2>&1

# 3) Fetch jwt_token.json and produce a single JSON object

jwt_response=$(curl -b /tmp/cookies.txt 'https://enlighten.enphaseenergy.com/app-api/jwt_token.json' 2>/dev/null)
full_token=$(echo "$jwt_response" | jq -r '.token')

echo "{\"status\":\"OK\",\"token\":\"${full_token}\"}"

```

## 2. Add Command Line Sensor in configuration.yaml

Paste the following into your configuration.yaml:
```
sensor:
  - platform: command_line
    name: "Enphase JWT"
    command: "bash /config/get_enphase_token.sh"
    scan_interval: 43200  # Refresh every 12 hours
    value_template: "{{ value_json.status }}"
    json_attributes:
      - token
```
Restart Home Assistant or reload the configuration.

## 3. Verify the Token
	•	Go to Developer Tools → States
	•	Look for sensor.enphase_jwt
	•	The state should show OK
	•	The token attribute will contain your JWT string

You can now use this token in any rest_command:
```
{{ state_attr('sensor.enphase_jwt', 'token') }}

```


# 🔋 Enphase Battery Scheduler for Home Assistant

This project provides a simple way to add scheduled Enphase battery charge/discharge slots via Home Assistant. It supports:

- CFG: Charge from Grid
- DTG: Discharge to Grid
- RBD: Reserve Battery Discharge

Users can configure the schedule using a Home Assistant script with selectable days, times, and schedule types.

---

## ✨ Features

- Create schedules for battery behaviour (CFG, DTG, RBD)
- Supports user and battery ID fields
- Allows multiple days selection via dropdown
- RESTful integration with Enlighten Enphase API

---

## 🧩 Setup Instructions

## 1. Add to `configuration.yaml`

Paste the following under your `rest_command:` section:

```yaml
rest_command:
  enphase_add_cfg_schedule:
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



## 2. Add Script in the UI (Scripts Editor

Go to Settings → Automations & Scenes → Scripts → + Add Script
Then paste the following:

```script
alias: Add Enphase Battery Schedule
sequence:
  - service: rest_command.enphase_add_cfg_schedule
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


⸻

## Requirements
	•	sensor.enphase_jwt with token attribute containing your valid JWT token
	•	Battery ID and User ID

