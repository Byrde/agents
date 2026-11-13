---
name: fuelix-cost-proxy
description: Artificial Analysis list prices are an accepted proxy for what Fuel iX charges per model
metadata:
  node_type: memory
  type: project
  originSessionId: f049ab7e-03d1-41c8-a19c-6f9ca0716bc0
  modified: 2026-10-28T17:24:11.518Z
---

Fuel iX lists no per-model price in OpenCode's model data. The user confirmed (2026-10-28) that the Artificial Analysis list price is a close enough proxy for the cost Fuel iX incurs per model. So the OpenCode model scoring (`scripts/opencode/lib/evaluate.py`) prices Fuel iX deployments at the AA list prices.

**Why:** The user said the AA cost is "a close enough proxy to the cost that fuelix incurs per model".

**How to apply:** Keep cost as a real factor for Fuel iX models. Do not treat them as free or as a flat rate. See also [[opencode-model-scoring]].
