# Inertia Rails Summary

## Documentation Selection

### Files Included (High Priority)
- **Server-side setup** - Critical Rails integration patterns
- **Forms** - Core functionality with non-obvious behaviors
- **Routing** - Essential for proper navigation
- **Responses** - Key server-client communication patterns
- **Shared data** - Important for state management
- **Validation** - Rails-specific error handling
- **Redirects** - Non-standard redirect behaviors
- **Partial reloads** - Performance optimization technique
- **File uploads** - Common but tricky feature
- **Events** - Important for advanced interactions

### Files Deprioritized/Ignored
- **awesome.md** - Just links, no technical content
- **who-is-it-for.md** - Marketing fluff
- **asset-versioning.md** - Basic, works out of the box
- **authentication.md** - Standard Rails auth, nothing Inertia-specific
- **client-side-setup.md** - Basic package installation instructions
- **scroll-management.md** - Works automatically
- **title-and-meta-tags.md** - Simple, well-documented elsewhere

## Critical Concepts

### Server-Side Setup

```ruby
# config/initializers/inertia.rb
InertiaRails.configure do |config|
  config.version = -> { Rails.application.config.assets.version }
  config.default_render = true
  config.deep_merge_shared_data = false
  
  # SSR configuration
  config.ssr_enabled = Rails.env.production?
  config.ssr_url = 'http://localhost:13714'
end
```

### Controller Patterns

```ruby
class UsersController < ApplicationController
  # Basic Inertia render - replaces render :template
  def index
    render inertia: 'Users/Index', props: {
      users: User.all.as_json(only: [:id, :name, :email])
    }
  end
  
  # Lazy evaluation for expensive props
  def show
    render inertia: 'Users/Show', props: {
      user: -> { User.find(params[:id]) },  # Only evaluated if needed
      posts: InertiaRails.lazy { @user.posts.limit(10) }  # Conditional loading
    }
  end
  
  # Shared data (available to all components)
  inertia_share do
    {
      current_user: current_user&.as_json(only: [:id, :name]),
      flash: flash.to_hash
    }
  end
end
```

### Forms with Svelte 5

```svelte
<script>
  import { router, useForm } from '@inertiajs/svelte'
  
  // Form helper with built-in state management
  const form = useForm({
    email: '',
    password: '',
    remember: false
  })
  
  function submit() {
    // Automatically handles CSRF, errors, and loading states
    $form.post('/login', {
      onSuccess: () => console.log('Logged in'),
      preserveScroll: true,  // Don't scroll to top
      preserveState: true    // Keep form data on error
    })
  }
</script>

<form on:submit|preventDefault={submit}>
  <input bind:value={$form.email} disabled={$form.processing}>
  {#if $form.errors.email}
    <span>{$form.errors.email}</span>
  {/if}
  
  <button disabled={$form.processing}>
    {$form.processing ? 'Logging in...' : 'Login'}
  </button>
</form>
```

### Navigation & Routing

```svelte
<script>
  import { Link, router } from '@inertiajs/svelte'
  
  // Programmatic navigation
  function navigate() {
    router.visit('/users', {
      method: 'get',
      data: { search: 'john' },
      replace: true,  // Replace history entry
      preserveState: true,
      only: ['users']  // Partial reload - only fetch 'users' prop
    })
  }
</script>

<!-- Link component handles Inertia navigation -->
<Link href="/users" method="get" as="button" preserve-scroll>
  View Users
</Link>

<!-- Manual visits for custom behavior -->
<button on:click={navigate}>Custom Navigation</button>
```

### Validation & Error Handling

```ruby
# Controller
def create
  @user = User.new(user_params)
  
  if @user.save
    redirect_to users_path, inertia: { notice: 'User created' }
  else
    # Errors automatically available in form.errors
    redirect_back fallback_location: new_user_path, inertia: { 
      errors: @user.errors 
    }
  end
end
```

```svelte
<!-- Svelte component -->
<script>
  import { page } from '@inertiajs/svelte'
  
  // Access validation errors from server
  $: errors = $page.props.errors || {}
</script>
```

### Partial Reloads (Performance)

```svelte
<script>
  import { router } from '@inertiajs/svelte'
  
  // Only reload specific props instead of full page
  function refreshPosts() {
    router.reload({ 
      only: ['posts'],  // Only fetch 'posts' prop
      onSuccess: () => console.log('Posts updated')
    })
  }
  
  // Exclude expensive props
  function quickUpdate() {
    router.visit('/dashboard', {
      except: ['analytics', 'reports']  // Skip these props
    })
  }
</script>
```

### File Uploads

```svelte
<script>
  import { useForm } from '@inertiajs/svelte'
  
  const form = useForm({
    name: '',
    avatar: null
  })
  
  function submit() {
    // Automatically uses FormData for file uploads
    $form.post('/users', {
      forceFormData: true,  // Force multipart even without files
      onProgress: (progress) => {
        console.log(`${progress.percentage}% uploaded`)
      }
    })
  }
</script>

<input type="file" on:change={(e) => $form.avatar = e.target.files[0]}>
```

### Shared Data Pattern

```ruby
# ApplicationController
class ApplicationController < ActionController::Base
  # Share data with ALL Inertia responses
  inertia_share do
    {
      auth: {
        user: current_user&.as_json(only: [:id, :name, :email])
      },
      flash: flash.to_hash,
      errors: flash[:errors]
    }
  end
  
  # Merge additional data in specific controllers
  inertia_share my_data: -> { expensive_calculation }
end
```

### Events & Lifecycle

```svelte
<script>
  import { router } from '@inertiajs/svelte'
  import { onMount } from 'svelte'
  
  onMount(() => {
    // Listen to Inertia navigation events
    const removeStartListener = router.on('start', (event) => {
      console.log(`Navigating to ${event.detail.visit.url}`)
    })
    
    const removeProgressListener = router.on('progress', (event) => {
      NProgress.set(event.detail.progress.percentage / 100)
    })
    
    const removeSuccessListener = router.on('success', (event) => {
      console.log('Page loaded successfully')
    })
    
    return () => {
      removeStartListener()
      removeProgressListener()
      removeSuccessListener()
    }
  })
</script>
```

### Redirects with Data

```ruby
# Special Inertia redirect behaviors
class PostsController < ApplicationController
  def update
    @post.update!(post_params)
    
    # Redirect with props (available on next page)
    redirect_to post_path(@post), inertia: { 
      notice: 'Post updated',
      highlight: true 
    }
  end
  
  def destroy
    @post.destroy!
    
    # 303 redirect (always GET) - important for DELETE/PUT
    redirect_to posts_path, status: 303
  end
end
```

### Advanced Patterns

#### Persistent Layouts

```svelte
<!-- Layout.svelte -->
<script>
  import { page } from '@inertiajs/svelte'
  export let title = 'Default Title'
</script>

<div>
  <nav>...</nav>
  <slot />  <!-- Page component renders here -->
</div>
```

```svelte
<!-- Page component -->
<script>
  import Layout from './Layout.svelte'
  export let posts = []
  
  // Specify layout (persists across navigation)
  export const layout = Layout
</script>
```

#### Deferred Props (Async Loading)

```ruby
def show
  render inertia: 'Post/Show', props: {
    post: post.as_json,
    comments: InertiaRails.defer { 
      sleep 2  # Simulate slow query
      @post.comments.includes(:user)
    }
  }
end
```

```svelte
<script>
  import { page } from '@inertiajs/svelte'
  
  // Comments will be undefined initially, then load async
  $: comments = $page.props.comments
</script>

{#if comments}
  <!-- Show comments -->
{:else}
  <div>Loading comments...</div>
{/if}
```

## Common Pitfalls

1. **Not using 303 redirects** after DELETE/PUT/PATCH - causes browser issues
2. **Forgetting `as_json`** on ActiveRecord objects - sends entire object
3. **Not using `only`/`except`** for partial reloads - defeats performance benefits
4. **Missing `preserve-scroll`** on filters/search - jarring UX
5. **Not handling `$form.processing`** state - users click submit multiple times
6. **Using regular `<a>` tags** instead of `<Link>` - causes full page reloads
7. **Not wrapping shared data in lambdas** - evaluates on every request even if not needed

## Key Differences from Traditional Rails

- No more `redirect_to :back` - use `redirect_back` with `fallback_location`
- No `render json:` for API responses - always use `render inertia:`
- Form errors don't render a template - they redirect back with errors in props
- No need for `remote: true` or Turbo - Inertia handles all Ajax
- CSRF tokens handled automatically - no need for `csrf_meta_tags` in forms
