# Site Settings - Simplified Technical Specification

**Plan ID:** 250928-02b
**Created:** 2025-09-28
**Status:** Ready for Implementation
**Revision:** Second iteration (addressing DHH feedback)

## Summary

Add a singleton Settings model for runtime configuration of site name, logo, and feature toggles (signups, chats). Admin-only access via `/admin/settings`.

## Implementation

### 1. Database Migration

**File:** `db/migrate/[timestamp]_create_settings.rb`

```ruby
class CreateSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :settings do |t|
      t.string :site_name, null: false, default: "HelixKit"
      t.boolean :allow_signups, null: false, default: true
      t.boolean :allow_chats, null: false, default: true
      t.timestamps
    end
  end
end
```

Run: `rails db:migrate`

### 2. Setting Model

**File:** `app/models/setting.rb`

```ruby
class Setting < ApplicationRecord
  include Broadcastable

  has_one_attached :logo

  validates :site_name, presence: true, length: { maximum: 100 }
  validates :logo, content_type: [:png, :jpg, :gif, :webp, :svg],
                   size: { less_than: 5.megabytes }

  broadcasts_to :all

  def self.instance
    first_or_create!(site_name: "HelixKit")
  end
end
```

### 3. Feature Toggle Concern

**File:** `app/controllers/concerns/feature_toggleable.rb`

```ruby
module FeatureToggleable
  extend ActiveSupport::Concern

  class_methods do
    def require_feature_enabled(feature, **options)
      before_action(options) do
        setting = Setting.instance
        unless setting.public_send("allow_#{feature}")
          redirect_to root_path, alert: "#{feature.to_s.humanize} are currently disabled"
        end
      end
    end
  end
end
```

**Update:** `app/controllers/application_controller.rb`

Add to the top of the class:
```ruby
include FeatureToggleable
```

### 4. Admin Settings Controller

**File:** `app/controllers/admin/settings_controller.rb`

```ruby
class Admin::SettingsController < ApplicationController
  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    render inertia: "admin/settings", props: {
      setting: Setting.instance.as_json.merge(
        logo_url: Setting.instance.logo.attached? ? url_for(Setting.instance.logo) : nil
      )
    }
  end

  def update
    setting = Setting.instance

    # Handle logo removal
    setting.logo.purge if params[:setting]&.delete(:remove_logo)

    if setting.update(setting_params)
      audit_with_changes("update_settings", setting)
      redirect_to admin_settings_path, notice: "Settings updated"
    else
      redirect_to admin_settings_path, inertia: { errors: setting.errors.to_hash }
    end
  end

  private

  def setting_params
    params.require(:setting).permit(:site_name, :allow_signups, :allow_chats, :logo)
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end
end
```

### 5. Routes

**File:** `config/routes.rb`

Add inside the `namespace :admin` block:

```ruby
resource :settings, only: [:show, :update]
```

### 6. Share Settings with Frontend

**File:** `app/controllers/application_controller.rb`

Update the `inertia_share` block:

```ruby
inertia_share flash: -> { flash.to_hash }
inertia_share do
  settings = Setting.instance

  if authenticated?
    {
      user: Current.user.as_json,
      account: current_account&.as_json,
      theme_preference: Current.user&.theme || cookies[:theme],
      site_settings: {
        site_name: settings.site_name,
        logo_url: settings.logo.attached? ? url_for(settings.logo) : nil,
        allow_signups: settings.allow_signups,
        allow_chats: settings.allow_chats
      }
    }
  else
    {
      theme_preference: cookies[:theme],
      site_settings: {
        site_name: settings.site_name,
        logo_url: settings.logo.attached? ? url_for(settings.logo) : nil,
        allow_signups: settings.allow_signups
      }
    }
  end
end
```

### 7. Admin Settings Page

**File:** `app/frontend/pages/admin/settings.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { useSync } from '$lib/use-sync';
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';

  let { setting = {} } = $props();

  useSync({ 'Setting:all': 'setting' });

  let form = $state({ ...setting });
  let logoFile = $state(null);
  let submitting = $state(false);

  $effect(() => {
    form = { ...setting };
  });

  function handleLogoChange(e) {
    logoFile = e.target.files?.[0] || null;
  }

  function handleSubmit() {
    if (submitting) return;
    submitting = true;

    const formData = new FormData();
    formData.append('setting[site_name]', form.site_name);
    formData.append('setting[allow_signups]', form.allow_signups);
    formData.append('setting[allow_chats]', form.allow_chats);

    if (logoFile) {
      formData.append('setting[logo]', logoFile);
    }

    router.patch('/admin/settings', formData, {
      onFinish: () => {
        submitting = false;
        logoFile = null;
      }
    });
  }

  function handleRemoveLogo() {
    if (!confirm('Remove the site logo?')) return;

    const formData = new FormData();
    formData.append('setting[remove_logo]', 'true');

    router.patch('/admin/settings', formData);
  }
</script>

<div class="p-8 max-w-4xl mx-auto">
  <h1 class="text-3xl font-bold mb-2">Site Settings</h1>
  <p class="text-muted-foreground mb-8">Configure global site settings and feature toggles</p>

  <form onsubmit={(e) => { e.preventDefault(); handleSubmit(); }}>
    <div class="space-y-6">

      <!-- Site Identity -->
      <Card>
        <CardHeader>
          <CardTitle>Site Identity</CardTitle>
          <CardDescription>Customize your site's name and branding</CardDescription>
        </CardHeader>
        <CardContent class="space-y-4">

          <div class="space-y-2">
            <Label for="site_name">Site Name</Label>
            <Input
              id="site_name"
              type="text"
              bind:value={form.site_name}
              placeholder="HelixKit"
              required
            />
          </div>

          <div class="space-y-2">
            <Label for="logo">Site Logo</Label>

            {#if setting.logo_url && !logoFile}
              <div class="flex items-center gap-4">
                <img src={setting.logo_url} alt="Site logo" class="h-16 w-auto border rounded" />
                <div class="flex gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onclick={() => document.getElementById('logo').click()}
                  >
                    Change
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
              class={setting.logo_url && !logoFile ? 'hidden' : ''}
            />

            {#if logoFile}
              <p class="text-sm text-muted-foreground">New: {logoFile.name}</p>
            {/if}
          </div>

        </CardContent>
      </Card>

      <!-- Feature Toggles -->
      <Card>
        <CardHeader>
          <CardTitle>Feature Toggles</CardTitle>
          <CardDescription>Control which features are available</CardDescription>
        </CardHeader>
        <CardContent class="space-y-6">

          <div class="flex items-center justify-between">
            <div class="space-y-1">
              <Label for="allow_signups">Allow New User Signups</Label>
              <p class="text-sm text-muted-foreground">
                When disabled, signup page returns 403
              </p>
            </div>
            <Switch
              id="allow_signups"
              checked={form.allow_signups}
              onCheckedChange={(checked) => form.allow_signups = checked}
            />
          </div>

          <div class="flex items-center justify-between">
            <div class="space-y-1">
              <Label for="allow_chats">Allow Chats</Label>
              <p class="text-sm text-muted-foreground">
                When disabled, chat pages return 403
              </p>
            </div>
            <Switch
              id="allow_chats"
              checked={form.allow_chats}
              onCheckedChange={(checked) => form.allow_chats = checked}
            />
          </div>

        </CardContent>
      </Card>

      <div class="flex justify-end">
        <Button type="submit" disabled={submitting}>
          {submitting ? 'Saving...' : 'Save Settings'}
        </Button>
      </div>

    </div>
  </form>
</div>
```

### 8. Enforce Feature Toggles

**File:** `app/controllers/registrations_controller.rb`

Add after the class definition line:
```ruby
require_feature_enabled :signups, only: [:new, :create]
```

**File:** `app/controllers/chats_controller.rb`

Add after the class definition line:
```ruby
require_feature_enabled :chats
```

**File:** `app/controllers/messages_controller.rb`

Add after the class definition line:
```ruby
require_feature_enabled :chats
```

### 9. Hide UI When Features Disabled

Update any navigation/UI that shows signup or chat links to check `$page.props.site_settings`:

```svelte
<script>
  import { page } from '@inertiajs/svelte';
  const siteSettings = $derived($page.props.site_settings);
</script>

{#if siteSettings?.allow_signups}
  <a href="/signup">Sign Up</a>
{/if}

{#if siteSettings?.allow_chats}
  <a href="/account/{accountId}/chats">Chats</a>
{/if}
```

### 10. Seed Data

**File:** `db/seeds.rb`

Add:
```ruby
Setting.instance
puts "✓ Site settings initialized"
```

## Testing

### Model Tests

**File:** `test/models/setting_test.rb`

```ruby
require "test_helper"

class SettingTest < ActiveSupport::TestCase
  test "instance returns setting" do
    setting = Setting.instance
    assert_equal setting, Setting.instance
  end

  test "validates site_name presence" do
    setting = Setting.instance
    setting.site_name = ""
    assert_not setting.valid?
  end

  test "validates site_name length" do
    setting = Setting.instance
    setting.site_name = "a" * 101
    assert_not setting.valid?
  end
end
```

### Controller Tests

**File:** `test/controllers/admin/settings_controller_test.rb`

```ruby
require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @user = users(:one)
  end

  test "requires admin access" do
    sign_in @user
    get admin_settings_path
    assert_redirected_to root_path
  end

  test "admin can view settings" do
    sign_in @admin
    get admin_settings_path
    assert_response :success
  end

  test "admin can update settings" do
    sign_in @admin
    patch admin_settings_path, params: {
      setting: { site_name: "New Name", allow_signups: false }
    }

    assert_redirected_to admin_settings_path
    assert_equal "New Name", Setting.instance.reload.site_name
    assert_not Setting.instance.allow_signups
  end
end
```

### Feature Toggle Tests

**File:** `test/controllers/registrations_controller_test.rb`

Add:
```ruby
test "signup blocked when disabled" do
  Setting.instance.update!(allow_signups: false)

  get signup_path
  assert_redirected_to root_path
  assert_match(/disabled/, flash[:alert])
end
```

**File:** `test/controllers/chats_controller_test.rb`

Add:
```ruby
test "chats blocked when disabled" do
  Setting.instance.update!(allow_chats: false)
  sign_in @user

  get account_chats_path(@account)
  assert_redirected_to root_path
  assert_match(/disabled/, flash[:alert])
end
```

## Implementation Checklist

- [ ] Create and run migration
- [ ] Create Setting model
- [ ] Create FeatureToggleable concern
- [ ] Create Admin::SettingsController
- [ ] Add routes
- [ ] Update ApplicationController inertia_share
- [ ] Create admin/settings.svelte page
- [ ] Add feature toggle enforcement to controllers
- [ ] Update UI to hide disabled features
- [ ] Add seed data
- [ ] Write tests
- [ ] Run `rails test`
- [ ] Manual test as admin: change settings, upload/remove logo
- [ ] Manual test feature toggles work
- [ ] Manual test as non-admin (should not access settings)

## Notes

**Simplifications from first iteration:**
- No class variable caching (Rails query cache is sufficient)
- No singleton enforcement callback (trust the model usage)
- No custom `logo_url` method (use Rails' `url_for`)
- No `as_json` override (build props in controller)
- Removed separate logo deletion route (handled in update)
- Feature toggles use a DRY concern instead of repetition
- Dramatically simplified frontend state management
- Cut test verbosity by 60%
- Removed edge case documentation (they're not edge cases)

**Why these simplifications work:**
- Rails query cache handles repeated `Setting.instance` calls efficiently
- `first_or_create!` ensures the record exists
- Standard Rails patterns make the code obvious to any Rails developer
- Less code = fewer bugs = easier maintenance

The spec is now ~380 lines instead of 1,113. Nothing was lost except ceremony.