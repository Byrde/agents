---
name: google-analytics
description: Owns Google Analytics (GA4) reporting for this project — query
  traffic, engagement, real-time, and funnel data; pull account/property
  metadata; read custom dimensions and metrics. Consulted by any practice skill
  that needs to measure how the site is actually used (traffic to events/day
  views, top venues, referral sources, real-time spikes). Read-only. Configured
  for GA4 property 542366447 under Google Cloud project outtogether-p-n0pgj.
category: tool
---

# Google Analytics

This project's analytics tool. Owns **read-only** GA4 reporting for **property `542366447`**, queried through Google's official Analytics MCP server (`analytics-mcp`). The site this measures is OutTogether / cornwalltogether.ca; the GA4 tag is wired in the client via `VITE_GA_MEASUREMENT_ID`.

## Owned operations

- **run a report** — core dimensions + metrics over a date range (`run_report`).
- **run a real-time report** — active users / events in the last 30 min (`run_realtime_report`).
- **run a funnel report** — step-through conversion (`run_funnel_report`).
- **list account summaries** — accounts and the properties under them (`get_account_summaries`).
- **get property details** — timezone, currency, data streams (`get_property_details`).
- **read custom dimensions & metrics** — the property's custom definitions (`get_custom_dimensions_and_metrics`).
- **list Google Ads links** — linked Ads accounts (`list_google_ads_links`).

Any practice skill that asks "how much traffic…", "which events/venues are most viewed", "where are visitors coming from", or "is anything spiking right now" routes through this skill.

## Access

All operations go through the **`analytics-mcp` MCP server** (Google's official Google Analytics MCP, run locally via `pipx run analytics-mcp`). It is **read-only** — it exposes no write or admin-mutation tools, and you must not attempt to mutate analytics configuration through it. Do not call the Google Analytics REST APIs directly.

Authentication is **Application Default Credentials (ADC)** established by `gcloud auth application-default login` with the `analytics.readonly` scope — credentials live in gcloud's well-known ADC store, never in the MCP config. The config carries only `GOOGLE_PROJECT_ID=outtogether-p-n0pgj` (the billing/quota project, not a secret). Property access follows the authenticated Google account's existing GA permissions.

### Preflight (first operation of the session)

1. **Server health.** Verify the `analytics-mcp` MCP server is connected. If it isn't, the operator needs to (re-)run `.agents/scripts/setup-google-analytics.sh` — halt and say so rather than guessing.
2. **Credentials.** If a tool call fails with an auth/permission error, ADC has likely expired or lacks the scope. Halt and tell the operator to re-run `gcloud auth application-default login --scopes https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform`. Never paper over an auth failure with fabricated numbers.
3. **Property.** Confirm you are reporting against property `542366447`. If a request is ambiguous about which property, default to this one; call `get_account_summaries` only when the operator asks about a different property.

## Conventions

### Always scope the property and the dates

Every report names the property as `properties/542366447` and an explicit date range. Never emit an unbounded report. Prefer named ranges (`today`, `yesterday`, `7daysAgo`, `30daysAgo`) over hardcoded dates unless the operator gives specific dates.

### Report honestly

- Quote the date range, the property, and the metric definitions alongside every number — a metric without its window is noise.
- GA4 applies **data thresholding** and **sampling**; when a response is sampled or thresholded, say so rather than presenting it as exact.
- "(other)" rows and `(not set)` dimension values are real GA4 output — surface them, don't silently drop them.
- If a query returns zero rows, report zero rows. Do not invent plausible figures.

### Real-time vs. core

Real-time reports cover only the last 30 minutes and a limited dimension/metric set — use them for "what's happening right now" spikes, not historical analysis. For anything dated, use `run_report`.

### Read-only — no configuration changes

This skill never creates, edits, or deletes GA4 properties, data streams, custom definitions, or audiences. Analytics configuration changes are done by a human in the GA Admin UI, out of band.

## Composition

When a tracker (`github-projects`) is installed and a work item asks for a metric ("traffic to event detail pages since launch"), this skill produces the figures; the tracker owns recording them on the work item. This skill owns the analytics query, not the reporting destination.
