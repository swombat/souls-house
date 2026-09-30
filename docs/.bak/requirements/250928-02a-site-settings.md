# Site Settings

Rather than have them set in ENV vars that are hard to change, I want some dynamic site settings to be configurable via the admin panel.

The site settings will include settings like the name of the site and the logo and functional toggles like whether to allow new user signups, whether to allow chats, etc.

## Rails side implementation

I think a Settings model will be a good fit for this. It doesn't belong to a specific Team, it is just global. Only site admins can access it, of course.

## Svelte side implementation

On the Svelte side I want an admin panel to edit the site settings.

It doesn't need to be extraordinarily complicated... just have a section for the site settings that includes at least the following settings for now:

- Site name
- Site logo (uploadable)
- Allow new user signups
- Allow chats

## Clarifications

**1. Admin Authorization:**
Use the existing admin system with `Current.user&.is_site_admin?` pattern and `require_site_admin` before_action. Settings controller will go in the `Admin::` namespace following the existing pattern.

**2. Settings Access Pattern:**
Implement as a singleton model with `Settings.current` class method that returns the cached singleton record. Pass relevant settings (like site_name) as Inertia shared props when needed. For feature toggles, check in controllers before allowing actions.

**3. Feature Toggle Enforcement:**
When "Allow new user signups" is disabled, hide signup UI elements and return 403/redirect on signup controller attempts. When "Allow chats" is disabled, hide chat UI and refuse chat-related actions in controllers.

**4. Settings Storage:**
Use a singleton pattern - one Settings record that always exists (seeded on first setup), accessed via `Settings.current`.

**5. Logo Handling:**
Use Active Storage with S3 storage. The app already has a default logo that will be used when no custom logo is uploaded.
