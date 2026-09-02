# Documentation Overview

This directory contains detailed documentation for the Helix Kit Rails application. Start here to understand the project structure and find the information you need.

## Quick Start

1. **Development Setup**: Run `bin/dev` to start the development server (Rails on port 3000, Vite for frontend assets)
2. **Database Setup**: Run `rails db:setup` to create and seed the database
3. **Run Tests**: Use `rails test`, `bun run test`, and `bun run test:unit` to run the test suite before declaring changes complete.
4. **Dev Credentials**: See [dev-credentials.md](./dev-credentials.md) for local development login details

## Documentation Index

### Core Documentation

- **[Architecture](./architecture.md)** - Application architecture, technology stack, and design patterns
- **[File System Structure](./file_system_structure.md)** - Complete directory structure and file organization for Rails and Svelte
- **[Testing](./testing.md)** - Testing strategy, frameworks, and best practices
- **[Commands](./commands.md)** - Complete list of development, testing, and deployment commands

### Feature Documentation

- **[Authentication](./authentication.md)** - User authentication system details
- **[RubyLLM Documentation](./ruby-llm/ruby-llm-overview.md)** - Comprehensive RubyLLM AI framework documentation
  - [Agentic Workflows](./ruby-llm/agentic-workflows.md) - Building advanced AI agent systems
  - [Model Registry](./ruby-llm/model-registry.md) - Model discovery and management across 500+ AI models
  - [Polymorphic Tools](./polymorphic-tools.md) - Domain-based tool consolidation pattern for scaling to 50+ capabilities
- **[Frontend](./frontend.md)** - Svelte, Inertia.js, and component organization
- **[Database](./database.md)** - PostgreSQL setup and Solid adapters configuration
- **[Database Backup](./database-backup.md)** - Automated daily backups to S3
- **[Icons](./icons.md)** - Comprehensive Phosphor Icons reference with 1500+ searchable icons
- **[JSON Attributes](./json-attributes.md)** - Declarative JSON serialization with automatic ID obfuscation
- **[Real-time Synchronization Usage](./synchronization-usage.md)** - How to use the real-time sync system to update Svelte components when Rails models change
- **[Real-time Synchronization Internals](./synchronization-internals.md)** - ⚠️ ONLY consult if explicitly asked to debug sync issues. Contains deep implementation details.

### Tech Stack Documentation

Important: those are summarise of the documentation with reference to a URL. When details of a specific feature are needed, use the fetcher sub-agent to fetch the entire documentation,

- **[Inertia Rails](./stack/inertia-rails.md)** - Summary of Inertia.js Rails adapter capabilities and features
- **[Svelte 5](./stack/svelte-5.md)** - Summary of Svelte 5 capabilities and features
- **[Pay Gem](./stack/pay-overview.md)** - Payment processing with Stripe, Paddle, and other processors
  - [Installation](./stack/pay/installation.md) - Setup and configuration
  - [Configuration](./stack/pay/configuration.md) - Credentials and settings
  - [Customers](./stack/pay/customers.md) - Customer management
  - [Payment Methods](./stack/pay/payment-methods.md) - Payment method handling
  - [Charges](./stack/pay/charges.md) - One-time payments
  - [Subscriptions](./stack/pay/subscriptions.md) - Recurring billing
  - [Webhooks](./stack/pay/webhooks.md) - Event handling
  - [Testing](./stack/pay/testing.md) - Testing with fake processor
  - [Stripe Integration](./stack/pay/stripe.md) - Stripe-specific features
  - [Paddle Billing](./stack/pay/paddle-billing.md) - Paddle Billing integration

## Project Overview

Helix Kit is a Rails 8 starter template that combines:
- **Backend**: Ruby on Rails 8 with PostgreSQL
- **Frontend**: Svelte 5 with Inertia.js for SPA-like experience
- **Styling**: Tailwind CSS with DaisyUI and ShadcnUI components
- **Authentication**: Built-in Rails 8 authentication system
- **Build Tools**: Vite for fast frontend builds

## Key Directories

See **[File System Structure](./file_system_structure.md)** for complete directory layout and organization.

## Getting Help

- Check the specific documentation files for detailed information
- Review the README.md for installation instructions
- Look at existing code patterns in the codebase for examples

## Browser Testing

Separate from the Playwright Component Testing described in `docs/testing.md`, the `agent-browser` skill should be used to test changes in a real browser before telling the user the change is complete.

Invoke it with `/agent-browser`. See `docs/playwright-testing.md` for more information.
