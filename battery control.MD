# Enphase Battery Control with Home Assistant

This setup lets you:

- Monitor when your Enphase battery is **charging from the grid** or **discharging to the grid**.
- Control these modes with **template switches** that run your Enphase control scripts.
- Keep switch state in sync with actual battery behaviour.

## 0. Prerequisites

You need MQTT in your Home Assistant environment. There are two parts:

1. **MQTT broker** (if you don’t already have one):
   - The recommended option is the [Mosquitto broker add-on](https://github.com/home-assistant/addons/tree/master/mosquitto).
   - Once installed, Home Assistant can use `mqtt://` to subscribe to topics.

2. **Enphase Envoy MQTT JSON add-on**
   - [vk2him/Enphase-Envoy-mqtt-json](https://github.com/vk2him/Enphase-Envoy-mqtt-json)
   - This publishes data from your Envoy to MQTT under the topic `/envoy/json`.

With both running, you’ll see JSON messages on `/envoy/json` that include battery, grid, and PV power.

## 1. Create Binary Sensors

We’ll extract from the `/envoy/json` payload:

- **Battery charging from grid** = battery charging (negative power) *and* grid importing.
- **Battery discharging to grid** = battery discharging (positive power) *and* grid exporting.

Add to `configuration.yaml` (or create via **Settings → Devices & Services → MQTT → + Add Entity**):

```yaml
mqtt:
  binary_sensor:
    - name: "Battery Charging from Grid"
      state_topic: "/envoy/json"
      device_class: power
      payload_on: "ON"
      payload_off: "OFF"
      value_template: >
        {% set bt = 100 %}   {# tolerance in W #}
        {% set gt = 150 %}   {# tolerance in W #}
        {% set batt = (value_json['meters']['storage']['agg_p_mw'] | float(0)) / 1000 %}
        {% set grid = (value_json['meters']['grid']['agg_p_mw'] | float(0)) / 1000 %}
        {{ 'ON' if (batt < -bt and grid > gt) else 'OFF' }}

    - name: "Battery Discharging to Grid"
      state_topic: "/envoy/json"
      device_class: power
      payload_on: "ON"
      payload_off: "OFF"
      value_template: >
        {% set bt = 100 %}
        {% set gt = 150 %}
        {% set batt = (value_json['meters']['storage']['agg_p_mw'] | float(0)) / 1000 %}
        {% set grid = (value_json['meters']['grid']['agg_p_mw'] | float(0)) / 1000 %}
        {{ 'ON' if (batt > bt and grid < -gt) else 'OFF' }}
```

## 2. Create Template Switches

Add this to your `configuration.yaml` (or `switches.yaml` if you split configs):

```yaml
switch:
  - platform: template
    switches:
      charge_battery_from_the_grid:
        friendly_name: "Charge Battery from Grid"
        value_template: "{{ is_state('binary_sensor.battery_charging_from_grid', 'on') }}"
        turn_on:
          service: script.enphase_battery_charge_from_grid_on
        turn_off:
          service: script.enphase_battery_charge_from_grid_off

      discharge_battery_to_the_grid:
        friendly_name: "Discharge Battery to Grid"
        value_template: "{{ is_state('binary_sensor.battery_discharging_to_grid', 'on') }}"
        turn_on:
          service: script.enphase_battery_discharge_to_grid_on
        turn_off:
          service: script.enphase_battery_discharge_to_grid_off
```

Restart Home Assistant after saving.

## 3. Create Template Switches via the UI

If you prefer to use the **Home Assistant UI** instead of YAML:

1. Go to **Settings → Devices & Services → Helpers → + Create Helper**.
2. Select **Template → Switch**.
3. Fill in the details for **Charge Battery from Grid**:

   - **Name:** `Charge Battery from Grid`
   - **Value template:**
     ```jinja
     {{ is_state('binary_sensor.battery_charging_from_grid', 'on') }}
     ```
   - **Turn on action:** call `script.enphase_battery_charge_from_grid_on`
   - **Turn off action:** call `script.enphase_battery_charge_from_grid_off`

## 4. Repeat for Discharge Battery to Grid

1. Go back to **Settings → Devices & Services → Helpers → + Create Helper**.
2. Select **Template → Switch** again.
3. Fill in the details for **Discharge Battery to Grid**:

   - **Name:** `Discharge Battery to Grid`
   - **Value template:**
     ```jinja
     {{ is_state('binary_sensor.battery_discharging_to_grid', 'on') }}
     ```
   - **Turn on action:** call `script.enphase_battery_discharge_to_grid_on`
   - **Turn off action:** call `script.enphase_battery_discharge_to_grid_off`
