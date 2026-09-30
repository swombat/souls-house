# File System Structure

This document provides a comprehensive overview of the HelixKit application's file system organization, covering both Rails backend and Svelte frontend components.

## Directory Overview

```
helix_kit/
├── app/                    # Main application code
├── bin/                    # Executable scripts
├── config/                 # Rails configuration
├── db/                     # Database files
├── docs/                   # Documentation
├── lib/                    # Custom libraries
├── log/                    # Application logs
├── node_modules/           # Node.js dependencies
├── public/                 # Static public files
├── storage/                # Active Storage files
├── test/                   # Test suite
├── tmp/                    # Temporary files
└── vendor/                 # Third-party code
```

## Rails Application Structure

### `/app` Directory

The heart of the Rails application, organized by responsibility:

```
app/
├── channels/               # ActionCable channels for WebSockets
│   └── application_cable/
│       ├── channel.rb
│       └── connection.rb
├── controllers/            # Request handling logic
│   ├── concerns/          # Shared controller modules
│   │   ├── authentication.rb
│   │   └── error_handling.rb
│   ├── application_controller.rb
│   ├── pages_controller.rb
│   ├── passwords_controller.rb
│   └── sessions_controller.rb
├── helpers/                # View helper methods
│   └── application_helper.rb
├── jobs/                   # Background job classes
│   └── application_job.rb
├── mailers/                # Email functionality
│   ├── application_mailer.rb
│   └── passwords_mailer.rb
├── models/                 # Database models
│   ├── concerns/          # Shared model modules
│   ├── application_record.rb
│   ├── current.rb
│   ├── session.rb
│   └── user.rb
├── views/                  # Server-rendered views (minimal)
│   ├── layouts/
│   │   ├── application.html.erb
│   │   ├── mailer.html.erb
│   │   └── mailer.text.erb
│   └── passwords_mailer/
│       ├── reset.html.erb
│       └── reset.text.erb
└── frontend/               # Svelte application (see below)
```

## Svelte Frontend Structure

### `/app/frontend` Directory

The complete Svelte 5 application with Inertia.js integration:

```
app/frontend/
├── entrypoints/            # Vite entry points
│   ├── application.js     # Main JavaScript entry
│   ├── inertia.js         # Inertia.js setup and configuration
│   └── application.css    # Tailwind CSS imports
├── pages/                  # Page components (route endpoints)
│   ├── Home.svelte        # Homepage component
│   ├── auth/              # Authentication pages
│   │   ├── SignIn.svelte
│   │   ├── SignUp.svelte
│   │   └── PasswordReset.svelte
│   └── Error.svelte       # Error page component
├── layouts/                # Layout wrappers
│   ├── layout.svelte      # Main app layout
│   └── auth-layout.svelte # Authentication layout
├── lib/                    # Shared frontend code
│   ├── components/        # Reusable components
│   │   ├── ui/           # ShadcnUI components
│   │   │   ├── button/
│   │   │   ├── card/
│   │   │   ├── input/
│   │   │   └── [other UI components]
│   │   ├── navbar.svelte # Navigation component
│   │   └── [custom components]
│   ├── stores/            # Svelte stores
│   │   ├── theme.js      # Theme management
│   │   └── user.js       # User state
│   └── utils.js          # Utility functions
└── routes/                 # JS Routes integration
    ├── index.js
    └── index.js.map
```

## Configuration Files

### `/config` Directory

Rails and application configuration:

```
config/
├── application.rb          # Main Rails application config
├── boot.rb                # Boot configuration
├── cable.yml              # ActionCable settings
├── cache.yml              # Caching configuration
├── credentials.yml.enc    # Encrypted credentials
├── database.yml           # Database connections
├── environment.rb         # Environment setup
├── environments/          # Per-environment settings
│   ├── development.rb
│   ├── production.rb
│   └── test.rb
├── initializers/          # Boot-time initializations
│   ├── content_security_policy.rb
│   ├── cors.rb
│   ├── filter_parameter_logging.rb
│   ├── inflections.rb
│   └── permissions_policy.rb
├── locales/               # Internationalization files
│   └── en.yml
├── master.key             # Decryption key (gitignored)
├── puma.rb               # Web server configuration
├── queue.yml             # Job queue settings
├── routes.rb             # Application routes
└── storage.yml           # Active Storage settings
```

## Database Structure

### `/db` Directory

Database migrations and schema:

```
db/
├── migrate/               # Migration files
│   └── [timestamp]_create_users.rb
├── cable_schema.rb       # ActionCable schema
├── cache_schema.rb       # Cache store schema
├── queue_schema.rb       # Job queue schema
├── schema.rb             # Main database schema
└── seeds.rb              # Database seed data
```

## Test Structure

### `/test` Directory

Rails test suite organization:

```
test/
├── application_system_test_case.rb
├── channels/             # Channel tests
├── controllers/          # Controller tests
│   ├── pages_controller_test.rb
│   └── sessions_controller_test.rb
├── fixtures/             # Test data
│   ├── files/
│   └── users.yml
├── helpers/              # Helper tests
├── integration/          # Integration tests
├── jobs/                 # Job tests
├── mailers/              # Mailer tests
│   └── previews/        # Email previews
├── models/              # Model tests
│   └── user_test.rb
├── system/              # System tests
└── test_helper.rb       # Test configuration
```

## Build and Development Files

### Root Configuration Files

```
helix_kit/
├── .gitignore            # Git ignore patterns
├── .rubocop.yml          # Ruby linting rules
├── .ruby-version         # Ruby version specification
├── Gemfile               # Ruby dependencies
├── Gemfile.lock          # Locked gem versions
├── mise.toml             # Pinned development runtimes
├── package.json          # JavaScript dependencies
├── bun.lock              # Locked Bun dependencies
├── Procfile.dev          # Development process manager
├── Rakefile              # Rake task definitions
├── config.ru             # Rack configuration
├── postcss.config.js     # PostCSS configuration
├── tailwind.config.js    # Tailwind CSS configuration
├── vite.config.ts        # Vite bundler configuration
└── vite.json             # Vite Rails integration config
```

## Key File Purposes

### Backend Files

- **Controllers**: Handle HTTP requests and render Inertia responses
- **Models**: Define data structures and business logic
- **Mailers**: Send transactional emails
- **Jobs**: Process background tasks asynchronously
- **Channels**: Manage WebSocket connections for real-time features

### Frontend Files

- **Pages**: Top-level components mapped to routes
- **Components**: Reusable UI elements
- **Layouts**: Wrapper components for consistent page structure
- **Stores**: Centralized state management
- **Entrypoints**: Vite build entry points

### Configuration Files

- **routes.rb**: Defines all application URLs and their handlers
- **database.yml**: Database connection settings per environment
- **credentials.yml.enc**: Encrypted sensitive configuration
- **vite.config.ts**: Frontend build tool configuration

## File Naming Conventions

### Rails Conventions

- **Models**: Singular, PascalCase (e.g., `User`, `Session`)
- **Controllers**: Plural, PascalCase with "Controller" suffix (e.g., `UsersController`)
- **Migrations**: Timestamp prefix with descriptive name (e.g., `20240101000000_create_users.rb`)
- **Views**: Match controller/action structure (e.g., `users/show.html.erb`)

### Svelte Conventions

- **Components**: PascalCase with `.svelte` extension (e.g., `Button.svelte`, `LoginForm.svelte`)
  - This includes all components in `/lib/components/` and its subdirectories
  - Layouts also use PascalCase (e.g., `Layout.svelte`, `AuthLayout.svelte`)
- **Pages**: snake_case matching Rails controller action names (e.g., `home.svelte`, `new.svelte`, `edit.svelte`)
  - Pages must match the exact controller action name for proper Inertia.js routing
  - Example: `RegistrationsController#check_email` → `registrations/check_email.svelte`
- **Test Files**: Match the component/page name with `.test.js` extension
  - Component tests: PascalCase (e.g., `LoginForm.test.js`)
  - Page tests: snake_case (e.g., `home.test.js`, `new.test.js`)
- **Stores**: camelCase with `.js` extension (e.g., `theme.js`)
- **Utilities**: camelCase for functions, UPPER_CASE for constants

**Note**: ShadcnUI components maintain their own naming convention (kebab-case) as per the library standards.

## Special Directories

### `/bin` Directory

Executable scripts for development and deployment:

- `dev`: Start development servers
- `rails`: Rails command runner
- `rake`: Task runner
- `setup`: Initial project setup

### `/public` Directory

Static files served directly by the web server:

- `robots.txt`: Search engine instructions
- `favicon.ico`: Browser tab icon
- Error pages (404.html, 500.html, etc.)

### `/storage` Directory

Active Storage file uploads (gitignored in production)

### `/tmp` Directory

Temporary files including:

- Cache files
- PID files
- Socket files
- Session files

### `/vendor` Directory

Third-party code not managed by package managers

## Environment-Specific Files

### Development Only

- `Procfile.dev`: Defines processes for development
- `.ruby-version`: Ensures consistent Ruby version
- `mise.toml`: Pins Ruby and Bun for local development
- `master.key`: Decrypts credentials (never commit!)

### Production Considerations

- Static assets compiled to `/public/assets`
- Logs written to `/log/production.log`
- File uploads stored in cloud storage (not `/storage`)

## Data Flow Through the File System

1. **Request arrives** at Rails router (`config/routes.rb`)
2. **Controller** (`app/controllers/`) processes the request
3. **Model** (`app/models/`) handles data operations
4. **Inertia response** sent with component name and props
5. **Svelte page** (`app/frontend/pages/`) renders on client
6. **Components** (`app/frontend/lib/components/`) provide UI
7. **Stores** (`app/frontend/lib/stores/`) manage client state

This structure supports a clear separation of concerns while maintaining the benefits of a monolithic application architecture.
