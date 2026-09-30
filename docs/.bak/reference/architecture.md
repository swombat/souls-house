# Architecture Documentation

## Technology Stack

### Backend
- **Ruby on Rails 8.0.2** - Web application framework
- **PostgreSQL** - Primary database
- **Solid Adapters** - Rails 8's new approach for cache, queue, and cable
  - `solid_cache` - Database-backed caching
  - `solid_queue` - Database-backed job queue
  - `solid_cable` - Database-backed ActionCable

### Frontend
- **Svelte 5** - Reactive UI framework with runes
- **Inertia.js** - Connects Rails backend with Svelte frontend
- **Vite** - Fast build tool and dev server
- **Tailwind CSS 4** - Utility-first CSS framework
- **DaisyUI** - Component library for Tailwind
- **ShadcnUI** - Customizable component library

## Application Architecture

### Request Flow
1. Browser makes request to Rails server
2. Rails controller processes request
3. Controller renders Inertia response with Svelte component name and props
4. Inertia client-side router loads the Svelte component
5. Svelte component renders with provided props

### Directory Structure

See **[File System Structure documentation](./file_system_structure.md)** for complete directory layout, file organization, and naming conventions.

## Key Design Patterns

### The Rails Way Philosophy

This application follows Rails conventions and DHH's philosophy:

1. **Fat models, skinny controllers** - Business logic belongs in models
2. **Convention over configuration** - Follow Rails patterns, don't fight them
3. **Concerns for shared behavior** - Extract truly shared patterns
4. **No unnecessary abstractions** - Avoid service objects and premature optimization

### Authorization Patterns

#### Association-Based Authorization (The Rails Way)
Authorization is handled through Rails associations, not database row-level security:

```ruby
# GOOD - Rails associations naturally scope access
@project = current_user.accounts.find(params[:account_id]).projects.find(params[:id])
# This will raise RecordNotFound if user doesn't have access - perfect!

# BAD - Manual permission checking with service objects
@project = Project.find(params[:id])
authorize! @project  # Don't do this - adds unnecessary abstraction
```

#### Key Principles:
- **Use associations for scoping**: `current_user.accounts` automatically limits to accessible accounts
- **Let Rails handle authorization**: RecordNotFound exceptions are your authorization
- **No row-level database security**: Authorization happens in Rails, not the database
- **Simple and clear**: Any Rails developer can understand the authorization logic

### Validation Philosophy

#### Rails Validations Only
All validation logic lives in Rails models, never in the database:

```ruby
# GOOD - Rails model validation
class Account < ApplicationRecord
  validates :name, presence: true
  validate :enforce_personal_account_limit
  
  private
  
  def enforce_personal_account_limit
    if personal? && users.count > 1
      errors.add(:base, "Personal accounts can only have one user")
    end
  end
end

# BAD - SQL constraints (never do this)
# execute <<-SQL
#   ALTER TABLE accounts ADD CONSTRAINT check_personal_single_user ...
# SQL
```

#### Why Rails Validations:
- **Better error messages**: Rails provides clear, user-friendly error messages
- **Database agnostic**: No vendor lock-in to PostgreSQL-specific features
- **Easier testing**: Test validations in Ruby, not complex SQL
- **Single source of truth**: All business logic in one place (the model)
- **More flexible**: Can easily add conditional validations and complex logic

### Business Logic Placement

#### Models Contain Business Logic
Following Rails conventions, business logic belongs in models:

```ruby
# GOOD - Business logic in model
class User < ApplicationRecord
  def self.register!(email)
    transaction do
      user = find_or_initialize_by(email_address: email)
      # ... registration logic here
    end
  end
end

# BAD - Service object (avoid these)
class RegistrationService
  def execute
    # This hides code smells and creates unnecessary abstraction
  end
end
```

#### Controllers Stay Thin
Controllers should only orchestrate, not implement logic:

```ruby
# GOOD - Thin controller
def create
  user = User.register!(params[:email])
  redirect_to check_email_path
rescue ActiveRecord::RecordInvalid => e
  redirect_to signup_path, inertia: { errors: e.record.errors }
end
```

### Parameter Processing

#### Controllers Handle Parameter Transformation
Parameter processing (like parsing comma-separated strings) belongs in controllers, not models:

```ruby
# GOOD - Controller processes parameters before passing to model
class Admin::AuditLogsController < ApplicationController
  def index
    logs = AuditLog.filtered(processed_filters)
    # ...
  end
  
  private
  
  def processed_filters
    filters = filter_params.dup
    
    # Convert comma-separated strings to arrays
    [:audit_action, :auditable_type].each do |key|
      if filters[key].is_a?(String) && filters[key].include?(",")
        filters[key] = filters[key].split(",").map(&:strip)
      end
    end
    
    filters
  end
end

# Model scopes remain clean and accept arrays
class AuditLog < ApplicationRecord
  scope :by_action, ->(action) { where(action: action) if action.present? }
  scope :by_type, ->(type) { where(auditable_type: type) if type.present? }
end
```

#### Why This Pattern:
- **Separation of Concerns**: Controllers handle HTTP concerns (parameter parsing), models handle data
- **Clean Scopes**: Model scopes remain simple and reusable
- **Testability**: Parameter processing can be tested in controller tests
- **Flexibility**: Different controllers can process parameters differently for the same model

### Inertia.js Integration

Controllers use Inertia to render Svelte components:

```ruby
class PagesController < ApplicationController
  def home
    render inertia: 'Home', props: {
      user: current_user&.slice(:id, :email, :name)
    }
  end
end
```

Redirects use `inertia_location`:
```ruby
inertia_location(root_path)
```

### Component Organization

1. **Page Components** (`app/frontend/pages/`)
   - One component per controller action
   - Named to match the controller/action pattern
   - Receive props from Rails controller

2. **Layout Components** (`app/frontend/layouts/`)
   - `layout.svelte` - Main application layout
   - `auth-layout.svelte` - Authentication pages layout

3. **Reusable Components** (`app/frontend/lib/components/`)
   - Shared UI components used across pages
   - ShadcnUI components in `ui/` subdirectory
   - Custom business components at root level

### State Management

1. **Component State** - Use Svelte 5 runes (`$state`, `$derived`)
2. **Shared State** - Svelte stores in `app/frontend/lib/stores/`
3. **Server State** - Props passed from Rails controllers
4. **Persistent State** - localStorage (see theme store example)

### Authentication Architecture

- Session-based authentication using Rails 8 built-in auth
- `Authentication` concern included in `ApplicationController`
- Session cookies for maintaining logged-in state
- BCrypt for password hashing
- Password reset via email tokens

### Database Architecture

- PostgreSQL as primary database
- Solid adapters use separate schemas for isolation:
  - `cable_schema.rb` - ActionCable connections
  - `cache_schema.rb` - Cache entries
  - `queue_schema.rb` - Background jobs
  - `schema.rb` - Main application schema

### Frontend Build Pipeline

1. **Development**
   - Vite dev server provides HMR (Hot Module Replacement)
   - Rails serves on port 3000, Vite on configured port
   - `bin/dev` starts both servers via Procfile.dev

2. **Production**
   - Vite builds optimized bundles
   - Assets served by Rails with fingerprinting
   - Configured in `vite.json` and `vite.config.ts`

## Security Considerations

### Built-in Protections
- CSRF protection enabled by default
- Secure session cookies
- Parameter filtering for sensitive data
- Content Security Policy configured
- SQL injection protection via ActiveRecord

### Authentication Security
- BCrypt password hashing
- Session tokens with expiration
- Password reset tokens expire
- Secure cookie flags in production

## Performance Optimizations

### Frontend
- Vite code splitting for optimal bundle sizes
- Svelte's compiled output is highly optimized
- Tailwind CSS purging unused styles
- Lazy loading of page components via Inertia

### Backend
- Database-backed caching with solid_cache
- Background job processing with solid_queue
- Efficient database queries with includes/joins
- PostgreSQL query optimization

## Extension Points

### Adding New Features
1. Create route in `config/routes.rb`
2. Add controller action with Inertia render
3. Create Svelte page component
4. Add any shared components to lib/components
5. Update navigation if needed

### Adding New UI Components
1. Check if ShadcnUI has the component
2. If not, create in `app/frontend/lib/components/`
3. Use Tailwind classes for styling
4. Consider DaisyUI for rapid prototyping

### Adding Background Jobs
1. Create job class in `app/jobs/`
2. Solid Queue will handle execution
3. Monitor via Rails console or future admin UI

### Adding Real-time Features
1. Create ActionCable channel
2. Solid Cable handles connections
3. Update Svelte components to subscribe
4. Consider using stores for real-time state