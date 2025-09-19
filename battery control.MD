# Enphase Battery Control with Home Assistant

This setup lets you:

- Monitor when your Enphase battery is **charging from the grid** or **discharging to the grid**.
- Control these modes with **template switches** that run your Enphase control scripts.
- Keep switch state in sync with actual battery behaviour.

---

## 0. Prerequisites

You need MQTT in your Home Assistant environment. There are two parts:

1. **MQTT broker** (if you don’t already have one):
   - The recommended option is the [Mosquitto broker add-on](https://github.com/home-assistant/addons/tree/master/mosquitto).
   - Once installed, Home Assistant can use `mqtt://` to subscribe to topics.

2. **Enphase Envoy MQTT JSON add-on**
   - [vk2him/Enphase-Envoy-mqtt-json](https://github.com/vk2him/Enphase-Envoy-mqtt-json)
   - This publishes data from your Envoy to MQTT under the topic `/envoy/json`.

With both running, you’ll see JSON messages on `/envoy/json` that include battery, grid, and PV power.

---

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
