# Application version

[`rails_app_version`](https://github.com/seuros/rails_app_version) reads the
application version from the root `VERSION` file, which is also included in
the Docker image. Bump `VERSION` only when introducing a breaking change or
when intentionally invalidating caches that include the application version
in their keys. Routine changes and deployments do not require a version bump.
Ruby code can read `Rails.application.version` and `Rails.application.env`.

Rails responses include `X-App-Version` and `X-App-Environment` headers,
configured in `config/app_version.yml`. Check them with
`curl -I http://localhost:3100/up`. The environment defaults to `Rails.env`;
set `RAILS_APP_ENV` to override the advertised name.

On Rails 8.1, supply `REVISION` as an environment variable or a root file
to append a short deploy revision to the version header.
