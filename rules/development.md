---
description: Architecture default — domain-driven design
trigger: always_on
---

# Architecture — use DDD

Default to domain-driven design. Scale it to the project: a small one needs a few
folders, not a framework.

- **Keep the domain pure.** Business logic depends on nothing: no ORM, no web framework,
  no infrastructure library. When it needs storage or mail, it declares a port.
- **Point the dependencies inward.** Use cases and adapters depend on the domain. The
  domain depends on neither. One composition root wires them.
- **Test to match.** Unit tests cover the domain and the use cases, with fake ports.
  Integration tests cover the adapters.
