

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

### 1. Add to `configuration.yaml`

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



**2. Add Script in the UI (Scripts Editor)**

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

🛠 Requirements
	•	sensor.enphase_jwt with token attribute containing your valid JWT token
	•	Battery ID and User ID

