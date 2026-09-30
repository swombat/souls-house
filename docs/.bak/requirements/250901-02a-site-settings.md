# Site Settings

Rather than have them set in ENV vars that are hard to change, I want most site settings to be configurable via the admin panel.

The site settings will include both basic settings like the name of the site or the site URL, as well as more sensitive details like API keys/secrets.

## Rails side implementation

I think a Settings model will be a good fit for this. It doesn't belong to a specific Team, it is just global. Only site admins can access it, of course.

I am not certain whether it makes sense to have a separate model (e.g. SiteSecrets) for api keys and the like. Please share your thoughts.

The settings needs to be able to save sensitive details like API keys/secrets, so it needs to be a secure way to store them, perhaps with two-way encryption using the Rails Master Key as a salt.

When returning those secure details to the frontend, the Rails backend should only share an obfuscated version, like 'ska...238', so the secrets are not leaked as JSON returns. But of course internally it needs to be able to fully decrypt them.

In terms of the API exposed to Svelte, the secret settings like API keys are write-only.

## Svelte side implementation

On the Svelte side I want an admin panel to edit the site settings.

It doesn't need to be extraordinarily complicated... just have a section for the site settings, and then have a sub-section for the secret settings.