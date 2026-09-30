# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🚨 CRITICAL DATABASE RULES - NEVER VIOLATE THESE 🚨

### NEVER WIPE OR RESET THE DEVELOPMENT DATABASE
- **NEVER run `rails db:drop` in development**
- **NEVER run `rails db:reset` in development**
- **NEVER run `rails db:setup` on an existing database**
- **NEVER run destructive ActiveRecord commands like `User.destroy_all` in development console**
- **NEVER truncate tables in development**
- The development database contains important data that must be preserved
- Only run migrations that are additive or safely reversible
- If you need to test something destructive, use the test database only

### NEVER KILL THE DEVELOPMENT SERVER
- **NEVER kill the Rails server process (pid in tmp/pids/server.pid)**
- **NEVER kill background bash processes running `bin/dev`**
- The development server runs on port 3100 (not 3000)
- If you need to test something, use the existing running server

## Essential Information

This is a Rails 8 + Svelte 5 application using Inertia.js. **Always check the `/docs/` folder for detailed documentation before making changes.**

## Quick Start

```bash
bin/dev          # Start development server (Rails + Vite)
bin/rails db:prepare # Prepare the intended local database
bin/rails test   # Run tests
```

## Documentation Structure

📁 **`/docs/` - All detailed documentation lives here**

Archived plans in `docs/.bak/` are historical, not implementation instructions.

Start with **[/docs/overview.md](/docs/overview.md)** which indexes all documentation:

- **[Architecture](/docs/architecture.md)** - Application structure, patterns, and technology stack
- **[Testing](/docs/testing.md)** - Testing strategy and how to write/run tests  
- **[Commands](/docs/commands.md)** - Complete development command reference

## Critical Information

### When Creating New Features
1. Check `/docs/architecture.md` for patterns and structure
2. Follow existing code conventions in similar files
3. Run tests after changes: `rails test`
4. Check linting: `bin/rubocop`
5. Test features using the `agent-browser` skill (invoke with `/agent-browser`)

### Technology Stack
- **Backend**: Rails 8 with PostgreSQL
- **Frontend**: Svelte 5 with Inertia.js
- **Styling**: Tailwind CSS + DaisyUI + ShadcnUI
- **Build**: Vite

### Key Directories
- `/app/frontend/` - Svelte components and frontend code
- `/app/controllers/` - Rails controllers (render Inertia components)
- `/config/routes.rb` - Application routes
- `/docs/` - Detailed documentation

## Always Remember

1. **NEVER WIPE THE DEVELOPMENT DATABASE** - See `/docs/database-safety.md`
2. **Read the docs first** - Check `/docs/` before implementing
3. **Follow patterns** - Look at existing code for conventions
4. **Test your changes** - Run `rails test` after modifications
5. **Security matters** - Never commit secrets, use credentials
6. **Preserve development data** - Never run `destroy_all` or `db:reset` in development