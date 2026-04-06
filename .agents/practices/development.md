Architectural Standard Operating Procedure

Unless explicitly overridden by massive scale requirements, all new system designs and code execution MUST default to the "Lite DDD" (Modular Monolith) Architecture. This structure optimizes for developer velocity and simplicity while maintaining strict dependency inversion.

1. The Universal "Lite" Folder Structure

project_root/
├── api/                                # Programmatic Use-Cases & Orchestration
│   ├── UserAPI.<ext>                   # Entry point for User-related business logic
│   ├── OrderAPI.<ext>                  # Entry point for Order-related business logic
│   └── (etc...)                        
│
├── domain/                             # Unified Business Logic & Contracts
│   ├── models/                         # Entities, Aggregate Roots, Value Objects
│   ├── events/                         # Domain Events
│   ├── exceptions/                     # Business rule violations
│   └── ports/                          # Interfaces for external needs (Repositories, etc.)
│
├── infrastructure/                     # Adapters & External Implementations
│   ├── database/                       # Concrete Port implementations (SQL, NoSQL)
│   └── external_services/              # Third-party integrations (e.g., Stripe, SendGrid)
│
└── Main.<ext>                          # The Composition Root (Dependency Injection wiring)

2. Strict Dependency Rules

domain/ (The Core): Has ZERO external dependencies. It contains the unified business logic for the entire application. Absolutely no ORMs, web frameworks, or infrastructure libraries are permitted here. If the domain needs to save data or send an email, it defines an interface (port).

infrastructure/ (The Implementer): Depends ONLY on domain/. Its sole purpose is to implement the interfaces (Ports) defined by the domain. It does NOT know about, import, or rely on the api/ layer.

api/ (The Orchestrator): Depends ONLY on domain/. Files here contain the primary application logic and use-cases. They fetch entities via domain ports, execute domain logic, and save state. They do not know about concrete infrastructure implementations.

Main (Composition Root): The single file that wires the application together. It is the only place that imports from all folders. It instantiates the infrastructure/ adapters and injects them into the api/ orchestrators.

3. Logical Separation over Physical Isolation

Because the domain is shared, Anti-Corruption Layers (ACLs) are not required for internal communication. The OrderAPI can safely utilize a User entity from the shared domain/models/ folder.

Maintain Discipline: Even though the domain is unified, strive for logical separation. Keep User logic in User models and Order logic in Order models. Use Domain Events (domain/events/) to trigger side effects across different conceptual domains.

4. Testing Strategy

Unit Tests: Exclusively target domain/ and api/. These tests should be lightning-fast because they require no external mocks aside from faking the defined Ports.

Integration Tests: Target infrastructure/ to validate database queries, network calls, and framework wiring.