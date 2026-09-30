# Theme Preference Persistence Implementation Plan (Revised)

## Summary
Add persistent theme preference storage for logged-in users using a JSON preferences column for extensibility. Theme selector moves to user dropdown menu with three explicit options (light, dark, system). Guest users continue using localStorage.

## Architecture Overview

### Design Decisions
- **JSON preferences column**: More extensible than a dedicated theme column, following DHH's suggestion
- **RESTful updates**: Use standard `PATCH /user` endpoint, no custom actions
- **Cookie fallback**: Store theme in cookies for faster initial renders
- **Simple and elegant**: Follow Rails conventions, avoid over-engineering

### Data Flow
1. Logged-in users: Rails User model (preferences JSON) → Cookie → Inertia props → Svelte
2. Guest users: Browser localStorage → mode-watcher (current behavior)
3. Theme changes saved via standard user update endpoint

## Implementation Steps

### 1. Database Changes ✅
- [x] Create migration to add `preferences` JSON column to users table
  ```ruby
  # db/migrate/xxx_add_preferences_to_users.rb
  class AddPreferencesToUsers < ActiveRecord::Migration[8.0]
    def change
      add_column :users, :preferences, :json, default: {}
    end
  end
  ```

### 2. Model Updates ✅
- [x] Add preferences handling to User model
  ```ruby
  # app/models/user.rb
  
  # Add store_accessor for preferences
  store_accessor :preferences, :theme
  
  # Add validation
  validates :theme, inclusion: { in: %w[light dark system] }, allow_nil: true
  
  # Set default theme
  after_initialize do
    self.theme ||= 'system' if new_record?
  end
  
  # Include preferences in as_json
  def as_json(options = {})
    super(options).merge('preferences' => preferences)
  end
  ```

### 3. Controller Updates ✅
- [x] Add theme preference to permitted params in UsersController
  ```ruby
  # app/controllers/users_controller.rb
  private
  
  def user_params
    params.require(:user).permit(:first_name, :last_name, :timezone, preferences: [:theme])
  end
  ```

- [x] Set theme cookie on successful update
  ```ruby
  # app/controllers/users_controller.rb
  def update
    if Current.user.update(user_params)
      # Set theme cookie for faster initial page loads
      if params[:user][:preferences]&.key?(:theme)
        cookies[:theme] = {
          value: Current.user.theme,
          expires: 1.year.from_now,
          httponly: true,
          secure: Rails.env.production?
        }
      end
      flash[:success] = "Settings updated successfully"
    else
      flash[:errors] = Current.user.errors.full_messages
    end
    
    redirect_to edit_user_path
  end
  ```

- [x] Include theme preference in ApplicationController inertia_share
  ```ruby
  # app/controllers/application_controller.rb
  inertia_share do
    {
      user: Current.user&.as_json(
        only: %i[id email_address first_name last_name timezone],
        methods: %i[full_name site_admin],
        include: { preferences: {} }
      ),
      # Include theme from cookie for initial render optimization
      theme_preference: Current.user&.theme || cookies[:theme]
    }
  end
  ```

### 4. Frontend Components

#### Navbar Component Updates
- [ ] Remove standalone theme toggle button for logged-in users
- [ ] Keep theme toggle for guest users only
- [ ] Add theme submenu to user dropdown
  ```svelte
  <!-- app/frontend/layouts/navbar.svelte -->
  <script>
    import { Sun, Moon, Monitor, Palette } from 'phosphor-svelte';
    import { setMode, resetMode } from 'mode-watcher';
    import { router } from '@inertiajs/svelte';
    
    let currentUser = $page.props.user;
    let currentTheme = currentUser?.preferences?.theme || 'system';
    
    async function updateTheme(theme) {
      // Update UI immediately
      if (theme === 'system') {
        resetMode();
      } else {
        setMode(theme);
      }
      
      // Save to server for logged-in users
      if (currentUser) {
        router.patch('/user', {
          user: {
            preferences: { theme }
          }
        }, {
          preserveState: true,
          preserveScroll: true,
          only: [] // Don't reload any props
        });
      }
      
      currentTheme = theme;
    }
  </script>
  
  <!-- In user dropdown menu -->
  {#if currentUser}
    <DropdownMenu.Sub>
      <DropdownMenu.SubTrigger>
        <Palette class="mr-2 size-4" />
        <span>Theme</span>
      </DropdownMenu.SubTrigger>
      <DropdownMenu.SubContent>
        <DropdownMenu.Item 
          onclick={() => updateTheme('light')}
          class={currentTheme === 'light' ? 'bg-accent' : ''}
        >
          <Sun class="mr-2 size-4" />
          Light
        </DropdownMenu.Item>
        <DropdownMenu.Item 
          onclick={() => updateTheme('dark')}
          class={currentTheme === 'dark' ? 'bg-accent' : ''}
        >
          <Moon class="mr-2 size-4" />
          Dark
        </DropdownMenu.Item>
        <DropdownMenu.Item 
          onclick={() => updateTheme('system')}
          class={currentTheme === 'system' ? 'bg-accent' : ''}
        >
          <Monitor class="mr-2 size-4" />
          System
        </DropdownMenu.Item>
      </DropdownMenu.SubContent>
    </DropdownMenu.Sub>
  {/if}
  ```

#### Layout Component Updates
- [ ] Initialize theme from user preference on mount
  ```svelte
  <!-- app/frontend/layouts/layout.svelte -->
  <script>
    import { setMode } from 'mode-watcher';
    import { page } from '$app/stores';
    
    // Apply user's theme preference on initial load
    $effect(() => {
      const userTheme = $page.props.user?.preferences?.theme;
      if (userTheme && userTheme !== 'system') {
        setMode(userTheme);
      }
    });
  </script>
  ```

### 5. User Settings Page Updates (Optional Enhancement)
- [ ] Add theme preference to settings form for consistency
  ```svelte
  <!-- app/frontend/pages/user/edit.svelte -->
  <FormField {form} name="preferences.theme">
    <FormControl>
      <Select 
        value={$formData.preferences?.theme || 'system'} 
        onchange={(e) => $formData.preferences = { ...$formData.preferences, theme: e.target.value }}
      >
        <option value="light">Light</option>
        <option value="dark">Dark</option>
        <option value="system">System</option>
      </Select>
    </FormControl>
    <FormDescription>Choose your preferred color theme</FormDescription>
  </FormField>
  ```

## Testing Strategy

1. **Model Tests**
   - Test preferences JSON column and store_accessor
   - Validate theme values
   - Test default value initialization

2. **Controller Tests**
   - Test theme updates through standard update action
   - Verify cookie setting on theme change
   - Test validation of invalid theme values

3. **Integration Tests**
   - Theme persistence across sessions for logged-in users
   - Guest users continue using localStorage
   - Immediate UI updates without page reload
   - Cookie-based fast initial render

## Benefits of This Approach

1. **Extensibility**: JSON preferences column can store future user preferences
2. **RESTful**: Uses standard Rails patterns, no custom actions
3. **Performance**: Cookie provides fast initial render without database lookup
4. **Simplicity**: Follows Rails conventions, easy to understand and maintain
5. **Progressive**: Works for both guests (localStorage) and users (database)

## Edge Cases

1. **Migration of existing users**: Default preferences to empty hash, theme defaults to 'system'
2. **Guest to logged-in transition**: Initial login respects localStorage until user changes preference
3. **Cookie/database sync**: Cookie updated on every theme change for consistency
4. **Invalid values**: Rails validation ensures only valid themes are stored

## Security Considerations

- Theme preference is non-sensitive data
- Standard CSRF protection on PATCH requests
- Cookies marked httponly and secure in production
- JSON column properly sanitized by Rails

## Performance Notes

- Cookie provides instant theme on page load (no flash of wrong theme)
- Preferences included in initial Inertia props (no extra requests)
- PATCH request uses `only: []` to avoid unnecessary prop updates
- Lightweight JSON column with minimal overhead

## Dependencies

- Existing: mode-watcher npm package
- Existing: Phosphor icons for UI
- No new external dependencies required

This revised plan follows Rails conventions more closely, uses RESTful patterns, and provides a cleaner, more extensible solution while still meeting all the original requirements.

## Backend Implementation Status ✅

**All backend changes have been successfully implemented and tested:**

1. **Migration applied**: Added `preferences` JSON column to users table with `{}` default
2. **User model updated**: 
   - Added `store_accessor :preferences, :theme`
   - Added theme validation (light, dark, system)
   - Added default theme initialization ('system')
   - Updated `as_json` to include preferences
3. **UsersController updated**:
   - Added preferences[:theme] to permitted parameters
   - Added cookie setting logic for theme updates
4. **ApplicationController updated**:
   - Added theme_preference to inertia_share for both authenticated and guest users
   - Cookie fallback for fast initial renders

**Testing confirmed**:
- ✅ Theme defaults to 'system' for new users
- ✅ Theme validation rejects invalid values (invalid, blue, auto, etc.)
- ✅ Theme accepts valid values (light, dark, system)
- ✅ Preferences stored as JSON in database
- ✅ as_json includes preferences object
- ✅ User updates work with preferences parameter
- ✅ Strong parameters correctly permit preferences[:theme]

**Ready for frontend integration** - The backend provides:
- RESTful `PATCH /user` endpoint with preferences support
- Theme preference in Inertia shared props
- Cookie-based fast initial theme loading
- Proper validation and error handling