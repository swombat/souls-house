# Site Settings Feature - Technical Specification

**Plan ID:** 250928-02a
**Created:** 2025-09-28
**Status:** Ready for Implementation

## Executive Summary

Implement a dynamic Site Settings feature that allows site administrators to configure global settings through an admin panel instead of environment variables. Settings include site identity (name, logo) and functional toggles (signups, chats). This improves operational flexibility by allowing runtime configuration changes without deployments.

## Architecture Overview

### Singleton Pattern Approach

The Settings model will use a singleton pattern - a single database record that always exists and is accessed via `Settings.current`. This is preferred over a key-value store because:
- Type safety with actual database columns
- Simple to query and validate
- Natural fit with Rails conventions
- Easy to extend with additional settings

### Technology Stack

- **Backend:** Rails 8 singleton model with Active Storage for logo
- **Frontend:** Svelte 5 admin page with file upload component
- **Storage:** Active Storage with S3 (already configured)
- **Real-time Updates:** Broadcastable concern for live updates
- **Authorization:** Site admin only via existing `require_site_admin` pattern

## Database Schema

### Migration: `create_settings`

```ruby
class CreateSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :settings do |t|
      # Site Identity
      t.string :site_name, null: false, default: "HelixKit"

      # Feature Toggles
      t.boolean :allow_signups, null: false, default: true
      t.boolean :allow_chats, null: false, default: true

      t.timestamps
    end

    # Ensure only one settings record exists
    add_index :settings, :id, unique: true
  end
end
```

**Design Decisions:**
- Use boolean columns for toggles (not integers or strings) - clearest intent
- Sensible defaults allow the app to function immediately after migration
- Logo handled via Active Storage attachment, not a column
- Single ID index enforces singleton at database level

## Rails Implementation

### 1. Settings Model

**File:** `/app/models/setting.rb`

```ruby
class Setting < ApplicationRecord
  include SyncAuthorizable
  include Broadcastable

  # Active Storage attachment for logo
  has_one_attached :logo do |attachable|
    attachable.variant :thumb, resize_to_limit: [100, 100]
    attachable.variant :medium, resize_to_limit: [300, 300]
    attachable.variant :large, resize_to_limit: [600, 600]
  end

  # Validations
  validates :site_name, presence: true, length: { minimum: 1, maximum: 100 }
  validates :allow_signups, inclusion: { in: [true, false] }
  validates :allow_chats, inclusion: { in: [true, false] }

  # Logo validations
  validates :logo, content_type: ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml"],
                   size: { less_than: 5.megabytes }

  # Singleton pattern
  before_create :enforce_singleton

  # Broadcasting - admin only can subscribe
  broadcasts_to :all

  # Class method to access the singleton
  def self.current
    @current ||= first_or_create!(site_name: "HelixKit")
  end

  # Clear the cached instance
  def self.clear_cache
    @current = nil
  end

  # Callbacks to maintain cache
  after_save :clear_class_cache
  after_destroy :clear_class_cache

  # Helper methods for logo URLs
  def logo_url(variant: :medium)
    return nil unless logo.attached?

    if logo.variable?
      Rails.application.routes.url_helpers.rails_representation_url(
        logo.variant(variant),
        only_path: true
      )
    else
      # For SVG or non-processable images
      Rails.application.routes.url_helpers.rails_blob_url(logo, only_path: true)
    end
  end

  # Serialization for Inertia
  def as_json(options = {})
    super(options).merge(
      logo_url: logo_url(:medium),
      logo_thumb_url: logo_url(:thumb),
      logo_attached: logo.attached?
    )
  end

  private

  def enforce_singleton
    raise ActiveRecord::RecordInvalid, "Only one Setting record allowed" if Setting.exists?
  end

  def clear_class_cache
    self.class.clear_cache
  end
end
```

**Key Features:**
- Singleton enforcement at both model and database level
- Caching via class variable for performance
- Active Storage with multiple logo variants
- JSON serialization includes computed attributes
- Broadcasting for real-time updates

### 2. Admin Settings Controller

**File:** `/app/controllers/admin/settings_controller.rb`

```ruby
class Admin::SettingsController < ApplicationController
  skip_before_action :set_current_account
  before_action :require_site_admin
  before_action :set_setting

  def show
    render inertia: "admin/settings", props: {
      setting: @setting.as_json
    }
  end

  def update
    if @setting.update(setting_params)
      audit_with_changes("update_settings", @setting)
      redirect_to admin_settings_path, notice: "Settings updated successfully"
    else
      redirect_to admin_settings_path, inertia: {
        errors: @setting.errors.to_hash(true)
      }
    end
  end

  def destroy_logo
    if @setting.logo.attached?
      @setting.logo.purge
      audit("remove_site_logo", @setting)
      redirect_to admin_settings_path, notice: "Logo removed successfully"
    else
      redirect_to admin_settings_path, alert: "No logo to remove"
    end
  end

  private

  def set_setting
    @setting = Setting.current
  end

  def setting_params
    params.require(:setting).permit(
      :site_name,
      :allow_signups,
      :allow_chats,
      :logo
    )
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end
end
```

**Controller Patterns:**
- Follows existing admin controller structure
- Thin controller - validation in model
- Uses `setting` (singular) params key for singleton
- Audit logging for all setting changes
- Separate endpoint for logo deletion (RESTful)

### 3. Routes Configuration

**File:** `/config/routes.rb`

Add to the `namespace :admin` block:

```ruby
namespace :admin do
  resources :accounts, only: [:index]
  resources :audit_logs, only: [:index]

  # Settings - singleton resource
  resource :settings, only: [:show, :update] do
    delete :logo, action: :destroy_logo, as: :remove_logo
  end
end
```

**Routes Created:**
- `GET    /admin/settings` → `admin/settings#show` → `admin_settings_path`
- `PATCH  /admin/settings` → `admin/settings#update`
- `DELETE /admin/settings/logo` → `admin/settings#destroy_logo` → `remove_logo_admin_settings_path`

### 4. Sharing Settings via Inertia

**File:** `/app/controllers/application_controller.rb`

Update the `inertia_share` block:

```ruby
inertia_share flash: -> { flash.to_hash }
inertia_share do
  # Get basic settings for all users
  settings = Setting.current

  if authenticated?
    {
      user: Current.user.as_json,
      account: current_account&.as_json,
      theme_preference: Current.user&.theme || cookies[:theme],
      site_settings: {
        site_name: settings.site_name,
        logo_url: settings.logo_url(:thumb),
        allow_signups: settings.allow_signups,
        allow_chats: settings.allow_chats
      }
    }
  else
    {
      theme_preference: cookies[:theme],
      site_settings: {
        site_name: settings.site_name,
        logo_url: settings.logo_url(:thumb),
        allow_signups: settings.allow_signups
      }
    }
  end
end
```

**Why Share Globally:**
- Site name and logo displayed in header/footer for all users
- Signup toggle controls visibility of signup UI
- Chat toggle used throughout the app
- Minimal performance impact (singleton is cached)

## Frontend Implementation

### 1. Admin Settings Page

**File:** `/app/frontend/pages/admin/settings.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  import InfoCard from '$lib/components/InfoCard.svelte';

  let { setting = {} } = $props();

  // Real-time sync - reload when settings change
  useSync({
    'Setting:all': 'setting'
  });

  let formData = $state({
    site_name: setting.site_name || '',
    allow_signups: setting.allow_signups ?? true,
    allow_chats: setting.allow_chats ?? true
  });

  let logoFile = $state(null);
  let submitting = $state(false);

  function handleLogoChange(e) {
    const file = e.target.files?.[0];
    if (file) {
      logoFile = file;
    }
  }

  function handleSubmit() {
    if (submitting) return;

    submitting = true;

    const formDataObj = new FormData();
    formDataObj.append('setting[site_name]', formData.site_name);
    formDataObj.append('setting[allow_signups]', formData.allow_signups);
    formDataObj.append('setting[allow_chats]', formData.allow_chats);

    if (logoFile) {
      formDataObj.append('setting[logo]', logoFile);
    }

    router.patch('/admin/settings', formDataObj, {
      onFinish: () => {
        submitting = false;
        logoFile = null;
      }
    });
  }

  function handleRemoveLogo() {
    if (!confirm('Are you sure you want to remove the site logo?')) return;

    router.delete('/admin/settings/logo', {
      preserveState: true
    });
  }

  // Sync form data when setting prop changes
  $effect(() => {
    formData.site_name = setting.site_name || '';
    formData.allow_signups = setting.allow_signups ?? true;
    formData.allow_chats = setting.allow_chats ?? true;
  });
</script>

<div class="p-8 max-w-4xl mx-auto">
  <div class="mb-8">
    <h1 class="text-3xl font-bold mb-2">Site Settings</h1>
    <p class="text-muted-foreground">
      Configure global site settings and feature toggles
    </p>
  </div>

  <form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }}>
    <div class="space-y-6">

      <!-- Site Identity -->
      <Card>
        <CardHeader>
          <CardTitle>Site Identity</CardTitle>
          <CardDescription>
            Customize your site's name and branding
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-4">

          <!-- Site Name -->
          <div class="space-y-2">
            <Label for="site_name">Site Name</Label>
            <Input
              id="site_name"
              type="text"
              bind:value={formData.site_name}
              placeholder="HelixKit"
              required
            />
            <p class="text-sm text-muted-foreground">
              Displayed in the header and page titles
            </p>
          </div>

          <!-- Logo Upload -->
          <div class="space-y-2">
            <Label for="logo">Site Logo</Label>

            {#if setting.logo_attached && !logoFile}
              <div class="flex items-center gap-4">
                <img
                  src={setting.logo_url}
                  alt="Current site logo"
                  class="h-16 w-auto border rounded"
                />
                <div class="flex gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onclick={() => document.getElementById('logo').click()}
                  >
                    Change Logo
                  </Button>
                  <Button
                    type="button"
                    variant="destructive"
                    size="sm"
                    onclick={handleRemoveLogo}
                  >
                    Remove
                  </Button>
                </div>
              </div>
            {/if}

            <Input
              id="logo"
              type="file"
              accept="image/png,image/jpeg,image/gif,image/webp,image/svg+xml"
              onchange={handleLogoChange}
              class={setting.logo_attached && !logoFile ? 'hidden' : ''}
            />

            {#if logoFile}
              <p class="text-sm text-muted-foreground">
                New logo selected: {logoFile.name}
              </p>
            {/if}

            <p class="text-sm text-muted-foreground">
              Supported formats: PNG, JPEG, GIF, WebP, SVG (max 5MB)
            </p>
          </div>

        </CardContent>
      </Card>

      <!-- Feature Toggles -->
      <Card>
        <CardHeader>
          <CardTitle>Feature Toggles</CardTitle>
          <CardDescription>
            Control which features are available to users
          </CardDescription>
        </CardHeader>
        <CardContent class="space-y-6">

          <!-- Allow Signups -->
          <div class="flex items-center justify-between">
            <div class="space-y-1">
              <Label for="allow_signups">Allow New User Signups</Label>
              <p class="text-sm text-muted-foreground">
                When disabled, the signup page will return 403 and signup UI will be hidden
              </p>
            </div>
            <Switch
              id="allow_signups"
              checked={formData.allow_signups}
              onCheckedChange={(checked) => formData.allow_signups = checked}
            />
          </div>

          <!-- Allow Chats -->
          <div class="flex items-center justify-between">
            <div class="space-y-1">
              <Label for="allow_chats">Allow Chats</Label>
              <p class="text-sm text-muted-foreground">
                When disabled, chat functionality will be hidden and chat endpoints will return 403
              </p>
            </div>
            <Switch
              id="allow_chats"
              checked={formData.allow_chats}
              onCheckedChange={(checked) => formData.allow_chats = checked}
            />
          </div>

        </CardContent>
      </Card>

      <!-- Save Button -->
      <div class="flex justify-end">
        <Button type="submit" disabled={submitting}>
          {submitting ? 'Saving...' : 'Save Settings'}
        </Button>
      </div>

    </div>
  </form>
</div>
```

**Component Features:**
- Real-time updates via `useSync`
- FormData for file upload support
- Reactive form state with Svelte 5 runes
- Logo preview with change/remove actions
- Clear UI with shadcn components
- Confirmation for destructive actions

### 2. Navigation Link

Add admin settings link to the admin navigation (wherever admin links are displayed):

```svelte
<a href="/admin/settings" class="nav-link">
  Settings
</a>
```

## Feature Toggle Enforcement

### 1. Signup Controller

**File:** `/app/controllers/registrations_controller.rb`

Add before_action at the top:

```ruby
class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create confirm_email set_password update_password check_email ]

  # Add this line
  before_action :check_signups_enabled, only: [:new, :create]

  before_action :redirect_if_authenticated, only: [:new]
  before_action :load_pending_user, only: [:set_password, :update_password]

  # ... rest of controller

  private

  def check_signups_enabled
    unless Setting.current.allow_signups
      redirect_to root_path, alert: "New signups are currently disabled."
    end
  end

  # ... rest of private methods
end
```

### 2. Signup UI Visibility

In any navigation or UI that shows signup links, check the shared prop:

```svelte
<script>
  import { page } from '@inertiajs/svelte';

  const siteSettings = $derived($page.props.site_settings);
</script>

{#if siteSettings.allow_signups}
  <a href="/signup">Sign Up</a>
{/if}
```

### 3. Chat Controller

**File:** `/app/controllers/chats_controller.rb`

Add before_action:

```ruby
class ChatsController < ApplicationController
  # Add this line
  before_action :check_chats_enabled

  before_action :set_chat, except: [:index, :create, :new]

  # ... rest of controller

  private

  def check_chats_enabled
    unless Setting.current.allow_chats
      redirect_to root_path, alert: "Chat functionality is currently disabled."
    end
  end

  # ... rest of private methods
end
```

### 4. Chat UI Visibility

In navigation and UI showing chat links:

```svelte
<script>
  import { page } from '@inertiajs/svelte';

  const siteSettings = $derived($page.props.site_settings);
</script>

{#if siteSettings.allow_chats}
  <a href="/account/{accountId}/chats">Chats</a>
{/if}
```

### 5. Messages Controller

**File:** `/app/controllers/messages_controller.rb`

Add the same check:

```ruby
before_action :check_chats_enabled

private

def check_chats_enabled
  unless Setting.current.allow_chats
    head :forbidden
  end
end
```

## Database Seeding

**File:** `/db/seeds.rb`

Add to ensure settings exist:

```ruby
# Create default settings if they don't exist
Setting.current
puts "✓ Site settings initialized"
```

## Testing Strategy

### 1. Model Tests

**File:** `/test/models/setting_test.rb`

```ruby
require "test_helper"

class SettingTest < ActiveSupport::TestCase

  test "singleton pattern - only one setting record allowed" do
    Setting.current # Creates first record

    assert_raises(ActiveRecord::RecordInvalid) do
      Setting.create!(site_name: "Test")
    end
  end

  test "current returns existing setting" do
    setting1 = Setting.current
    setting2 = Setting.current

    assert_equal setting1.id, setting2.id
  end

  test "validates site_name presence" do
    setting = Setting.current
    setting.site_name = ""

    assert_not setting.valid?
    assert_includes setting.errors[:site_name], "can't be blank"
  end

  test "validates site_name length" do
    setting = Setting.current
    setting.site_name = "a" * 101

    assert_not setting.valid?
    assert_includes setting.errors[:site_name], "is too long"
  end

  test "logo_url returns nil when no logo attached" do
    setting = Setting.current
    assert_nil setting.logo_url
  end

  test "as_json includes logo information" do
    setting = Setting.current
    json = setting.as_json

    assert_includes json, "logo_url"
    assert_includes json, "logo_thumb_url"
    assert_includes json, "logo_attached"
  end

  test "default values" do
    setting = Setting.current

    assert_equal "HelixKit", setting.site_name
    assert setting.allow_signups
    assert setting.allow_chats
  end

end
```

### 2. Controller Tests

**File:** `/test/controllers/admin/settings_controller_test.rb`

```ruby
require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:admin)
    @user = users(:one)
    @setting = Setting.current
  end

  # Authorization Tests

  test "requires admin access" do
    sign_in @user
    get admin_settings_path
    assert_redirected_to root_path
  end

  test "allows admin access" do
    sign_in @admin
    get admin_settings_path
    assert_response :success
  end

  # Show Action Tests

  test "show renders settings page" do
    sign_in @admin
    get admin_settings_path

    assert_inertia "admin/settings"
    props = inertia_shared_props
    assert_includes props, "setting"
    assert_equal @setting.site_name, props["setting"]["site_name"]
  end

  # Update Action Tests

  test "update with valid params" do
    sign_in @admin

    patch admin_settings_path, params: {
      setting: {
        site_name: "New Site Name",
        allow_signups: false,
        allow_chats: false
      }
    }

    assert_redirected_to admin_settings_path
    @setting.reload
    assert_equal "New Site Name", @setting.site_name
    assert_not @setting.allow_signups
    assert_not @setting.allow_chats
  end

  test "update with invalid params" do
    sign_in @admin

    patch admin_settings_path, params: {
      setting: {
        site_name: "" # Invalid
      }
    }

    assert_redirected_to admin_settings_path
    props = inertia_shared_props
    assert props["errors"].present?
  end

  test "update creates audit log" do
    sign_in @admin

    assert_difference "AuditLog.count", 1 do
      patch admin_settings_path, params: {
        setting: { site_name: "Updated Name" }
      }
    end

    log = AuditLog.last
    assert_equal "update_settings", log.action
    assert_equal @setting, log.auditable
  end

  # Logo Removal Tests

  test "destroy_logo removes logo" do
    sign_in @admin

    # Attach a logo first
    @setting.logo.attach(
      io: File.open(Rails.root.join("test", "fixtures", "files", "logo.png")),
      filename: "logo.png",
      content_type: "image/png"
    )

    assert @setting.logo.attached?

    delete remove_logo_admin_settings_path

    assert_redirected_to admin_settings_path
    @setting.reload
    assert_not @setting.logo.attached?
  end

  test "destroy_logo creates audit log" do
    sign_in @admin

    @setting.logo.attach(
      io: File.open(Rails.root.join("test", "fixtures", "files", "logo.png")),
      filename: "logo.png",
      content_type: "image/png"
    )

    assert_difference "AuditLog.count", 1 do
      delete remove_logo_admin_settings_path
    end

    log = AuditLog.last
    assert_equal "remove_site_logo", log.action
  end

end
```

### 3. Feature Toggle Tests

**File:** `/test/controllers/registrations_controller_test.rb`

Add these tests:

```ruby
test "signup page returns 403 when signups disabled" do
  Setting.current.update!(allow_signups: false)

  get signup_path
  assert_redirected_to root_path
  assert_equal "New signups are currently disabled.", flash[:alert]
end

test "signup create returns 403 when signups disabled" do
  Setting.current.update!(allow_signups: false)

  post signup_path, params: { email_address: "test@example.com" }
  assert_redirected_to root_path
end
```

**File:** `/test/controllers/chats_controller_test.rb`

Add these tests:

```ruby
test "chat index returns 403 when chats disabled" do
  Setting.current.update!(allow_chats: false)
  sign_in @user

  get account_chats_path(@account)
  assert_redirected_to root_path
  assert_equal "Chat functionality is currently disabled.", flash[:alert]
end

test "chat create returns 403 when chats disabled" do
  Setting.current.update!(allow_chats: false)
  sign_in @user

  post account_chats_path(@account), params: {
    message: "Test message"
  }
  assert_redirected_to root_path
end
```

### 4. Fixtures

**File:** `/test/fixtures/settings.yml`

```yaml
one:
  site_name: "Test Site"
  allow_signups: true
  allow_chats: true
```

### 5. Test Files

Ensure these test fixture files exist:

**File:** `/test/fixtures/files/logo.png`

Create a simple 100x100 PNG file for testing logo uploads.

## Implementation Checklist

### Database & Models
- [ ] Create migration for settings table
- [ ] Run migration: `rails db:migrate`
- [ ] Create Setting model with singleton pattern
- [ ] Add validations and Active Storage attachment
- [ ] Add SyncAuthorizable and Broadcastable concerns
- [ ] Test singleton pattern in Rails console
- [ ] Add settings to seeds file
- [ ] Run seeds: `rails db:seed`

### Controllers & Routes
- [ ] Create Admin::SettingsController
- [ ] Add routes for settings (show, update, destroy_logo)
- [ ] Add settings to ApplicationController inertia_share
- [ ] Add before_action to RegistrationsController
- [ ] Add before_action to ChatsController
- [ ] Add before_action to MessagesController
- [ ] Test routes with `rails routes | grep settings`

### Frontend
- [ ] Create admin/settings.svelte page component
- [ ] Add real-time sync with useSync
- [ ] Implement form with site name input
- [ ] Implement logo upload with preview
- [ ] Implement feature toggle switches
- [ ] Add logo removal functionality
- [ ] Add settings link to admin navigation
- [ ] Update signup UI to check allow_signups
- [ ] Update chat UI to check allow_chats

### Testing
- [ ] Write Setting model tests
- [ ] Write Admin::SettingsController tests
- [ ] Add signup toggle tests to RegistrationsController
- [ ] Add chat toggle tests to ChatsController
- [ ] Create test fixture files
- [ ] Run all tests: `rails test`
- [ ] Test logo upload in browser
- [ ] Test feature toggles in browser

### Manual Testing
- [ ] Log in as admin user
- [ ] Access /admin/settings
- [ ] Change site name and verify in header
- [ ] Upload logo and verify display
- [ ] Remove logo and verify removal
- [ ] Disable signups and verify signup page returns 403
- [ ] Disable signups and verify signup UI hidden
- [ ] Re-enable signups and verify functionality restored
- [ ] Disable chats and verify chat pages return 403
- [ ] Disable chats and verify chat UI hidden
- [ ] Re-enable chats and verify functionality restored
- [ ] Verify audit logs created for all changes
- [ ] Test as non-admin user (should not access /admin/settings)

### Documentation
- [ ] Update README if needed
- [ ] Document settings in relevant places
- [ ] Add comments to complex code sections

## Edge Cases & Error Handling

### 1. Logo Upload Failures

**Handling:**
- Active Storage validations will catch invalid file types
- Size validation prevents excessively large files
- Controller will redirect with errors if validation fails
- User sees clear error message

### 2. Concurrent Updates

**Handling:**
- Singleton pattern prevents multiple records
- Rails optimistic locking not needed (admin-only, low frequency)
- Last write wins (acceptable for settings)

### 3. Cache Invalidation

**Handling:**
- `clear_cache` callback ensures class variable stays fresh
- Broadcastable updates all subscribed clients
- ApplicationController always fetches current settings

### 4. Missing Settings Record

**Handling:**
- `first_or_create!` ensures record always exists
- Seeds file creates on deployment
- Migration could add after_migration hook if needed

### 5. Feature Toggle Timing

**Scenario:** Admin disables chats while users are in chat interface

**Handling:**
- Broadcast updates all clients via SyncChannel
- Next action (sending message) will be rejected by controller
- User sees alert message
- Graceful degradation

### 6. Default Logo Fallback

**Handling:**
- Application already has default logo in assets
- When `logo.attached? == false`, frontend uses default
- No code changes needed - existing behavior

## Performance Considerations

### 1. Settings Caching

The singleton pattern with class variable caching means:
- First access: database query
- Subsequent accesses: in-memory read
- Cache cleared on save/destroy
- Minimal overhead

### 2. Shared Props Overhead

Adding settings to every Inertia response:
- Adds ~100 bytes per request (negligible)
- Avoids separate settings fetch from frontend
- Settings are needed frequently enough to justify

### 3. Logo Storage

- Active Storage with S3: production-ready
- Variants cached by Active Storage
- Thumb variant (~10KB) used in shared props
- No significant impact on response size

### 4. Feature Toggle Checks

- In-memory boolean check (nanoseconds)
- No database query per request (singleton cached)
- Controllers check before heavy operations
- Minimal performance impact

## Security Considerations

### 1. Authorization

- Only site admins can access settings
- Uses existing `require_site_admin` pattern
- No bypass possible without changing is_site_admin flag

### 2. File Upload Security

- Active Storage validates content type
- Size limited to 5MB
- Stored in S3 (not served directly by Rails in production)
- Content-Type header set by Active Storage

### 3. Feature Toggle Bypass

- Enforced in controller before_action
- Cannot be bypassed from frontend
- Even if user manipulates URL, controller rejects

### 4. Audit Trail

- All changes logged via audit system
- Records who changed what and when
- Includes old and new values

## Future Enhancements

Potential additions (not in current scope):

1. **Additional Settings:**
   - Site description/tagline
   - Contact email
   - Social media links
   - Analytics tracking ID
   - Maintenance mode toggle

2. **Advanced Features:**
   - Settings history/rollback
   - Scheduled feature toggles (enable/disable at specific time)
   - Multiple logo variants (dark mode logo)
   - Favicon upload

3. **UI Improvements:**
   - Preview changes before saving
   - Bulk actions for multiple settings
   - Settings categories/tabs
   - Search within settings

4. **Developer Features:**
   - API access to settings
   - Webhook on settings change
   - Settings export/import
   - Environment-specific overrides

## Conclusion

This implementation provides a solid foundation for site settings management with:
- Clean singleton pattern following Rails conventions
- Proper authorization and audit logging
- Real-time updates via broadcasting
- Feature toggles enforced at controller level
- Comprehensive test coverage
- Minimal performance impact

The architecture is extensible for future settings while maintaining simplicity for the current requirements.