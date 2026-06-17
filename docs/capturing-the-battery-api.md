# Capturing the Enphase Battery API with chrome-devtools-mcp

This runbook drives **your own Chrome** with
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) to record the
exact network calls the Enlighten **Battery Profile UI** fires for each action, so the
`rest_command`s in [`samples/configuration.yaml`](../samples/configuration.yaml) stay
provably correct (and so we can add the schedule **edit/change** call we don't have yet).

## Why local, and why pre-login

- The capture must run **on your machine** — `chrome-devtools-mcp` controls a browser on
  whatever host runs the server, and a cloud Claude session can't reach your localhost,
  can't complete your 2FA login, and shouldn't hold your credentials.
- We use **pre-login**: *you* log into Chrome, and the tools only **read** the network. The
  automation never types your email/password and Claude never sees them.

> ⚠️ Security: a remote-debugging port lets *any* local app control that Chrome. Use the
> dedicated profile shown below and **close that Chrome window when you're done**.

## Prerequisites

- Node.js LTS and `npx` (the server runs via `npx chrome-devtools-mcp@latest`).
- Google Chrome (stable or newer).
- Claude Code running **locally** in this repo.

## Step A — Launch a dedicated, logged-in Chrome

Quit all Chrome windows first, then start a throwaway profile with the debugging port:

```bash
# macOS
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 --user-data-dir="$HOME/enphase-chrome-profile"

# Linux
google-chrome --remote-debugging-port=9222 --user-data-dir="$HOME/enphase-chrome-profile"
```

```bat
:: Windows (cmd)
chrome.exe --remote-debugging-port=9222 --user-data-dir="%USERPROFILE%\enphase-chrome-profile"
```

In that window: log into `https://enlighten.enphaseenergy.com` (complete 2FA), then open
your battery settings / Battery Profile UI so the toggles and schedule editor are visible.

## Step B — Point Claude Code at the running Chrome

This repo ships [`.mcp.json`](../.mcp.json) which registers the server with
`--browser-url=http://127.0.0.1:9222` so it **attaches** to the Chrome you just logged into
(instead of launching its own):

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--browser-url=http://127.0.0.1:9222"]
    }
  }
}
```

Start Claude Code in the repo and approve the `chrome-devtools` MCP server. Confirm it's
attached by asking it to run `list_network_requests` — you should see the page's traffic.

## Step C — Capture loop (one action at a time)

For **each** action below, do this:

1. `list_network_requests` — baseline.
2. Perform **one** action in the Chrome UI (e.g. turn Charge from Grid **on**).
3. `list_network_requests` again — find the new request whose URL contains
   `/service/batteryConfig/api/v1/`.
4. `get_network_request` on it and record: **method**, **URL**, **request body (JSON)**,
   and the **header _names_** (not their values).

Actions to capture:

| Action | Expect (to confirm) |
| --- | --- |
| Charge from Grid — ON, then OFF | `PUT …/batterySettings/{site}?userId=…&source=enho`, body `{"chargeFromGrid": true/false, …}` |
| Discharge to Grid — ON, then OFF | `PUT …/batterySettings/{site}…`, body `{"dtgControl": {"enabled": …}}` |
| Restrict Battery Discharge — ON, then OFF | `PUT …/batterySettings/{site}…`, body `{"rbdControl": {"enabled": …}}` |
| Schedule — **add** | `POST …/battery/sites/{site}/schedules` |
| Schedule — **edit / change** *(the new one)* | likely `PUT …/battery/sites/{site}/schedules/{id}` — confirm method, URL, body |
| Schedule — **delete** | `POST …/battery/sites/{site}/schedules/{id}/delete` |

You can let the model drive the page (`navigate_page` / `take_snapshot` / `click` /
`fill_form`) instead of clicking manually, but manual clicks + reading the network is the
simplest, most transparent flow.

## Step D — Turn captures into `rest_command`s (with redaction)

For each captured request, update [`samples/configuration.yaml`](../samples/configuration.yaml)
(and mirror in [`README.md`](../README.md)):

- **URL** → template the dynamic parts: `{{ battery_id }}`, `{{ user_id }}`, `{{ schedule_id }}`.
- **Headers** → reuse the shared anchor: `headers: *enphase_headers` (add per-command extras
  only, e.g. `accept` on delete). The anchor already carries `e-auth-token` / `x-xsrf-token`
  / `cookie` / `username` / `origin` / `referer` as Jinja templates.
- **Payload** → the captured JSON body with dynamic fields as `{{ … }}`.
- **New command**: add `enphase_edit_schedule` for the edit/change call once its shape is
  confirmed.

### 🔒 Never commit secrets

Captured requests contain a **JWT** (`e-auth-token`), **session cookies**, the
**XSRF token**, and your real **`site_id` / `user_id`**. None of these go into git. Only the
request *shape* (method, URL pattern, header names, body fields) becomes a template.

Run this before committing — it must print nothing:

```bash
grep -rnE 'eyJ[A-Za-z0-9_-]{10}|BP-XSRF-Token=[A-Za-z0-9-]{8}|_enlighten_[0-9]+_session=' samples README.md docs
```

That catches a leaked **JWT** (`eyJ…`, used by both `e-auth-token` and the
`enlighten_manager_token_production` cookie), an **XSRF cookie value**
(`BP-XSRF-Token=<value>`), or the **Rails session cookie** (`_enlighten_…_session=<value>`).
Also eyeball the diff to confirm no real 7-digit `site_id`/`user_id` remains — those must be
`{{ battery_id }}` / `{{ user_id }}` placeholders.

## Verification

- Each action produced a **2xx** `batteryConfig` request with a JSON body.
- After updating the commands, in Home Assistant → **Developer Tools → Actions**, call each
  `rest_command` and confirm a 2xx, matching the captured shapes; the
  `sensor.enphase_schedules` reflects adds/edits/deletes.
- The secret-scan grep above prints nothing.
