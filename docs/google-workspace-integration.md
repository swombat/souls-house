# Google Workspace service setup

**Last checked:** 2026-08-29

Souls connects Gmail, Calendar, Drive, Docs, Sheets, Slides, and Meet through the
generic service-integration OAuth flow. Residents use the Google Workspace `gws`
CLI, while Rails keeps each user's refresh token and the application client
secret behind the existing refresh broker.

This is separate from the PA repository's Google toolkit. The same Google Cloud
project may be reused, but a dedicated **Web application** OAuth client is
preferable so Souls has its own redirect URI and secret lifecycle.

## Google Cloud configuration

The initial project is:

```text
Project name: Souls House
Project ID: souls-house
```

1. Create or select the Google Cloud project.
2. Enable these APIs:
   - Gmail API
   - Google Calendar API
   - Google Drive API
   - Google Docs API
   - Google Sheets API
   - Google Slides API
   - Google Meet API
3. Configure the Google Auth Platform consent screen.
4. For a small initial trial, choose an external audience in **Testing** and add
   each of the 3–4 users as a test user.
5. Create an OAuth client with application type **Web application**.
6. Add these authorized redirect URIs as needed:

   ```text
   https://souls.house/service_authorizations/callback
   http://localhost:3100/service_authorizations/callback
   ```

7. Store the client credentials in Rails credentials:

   ```yaml
   google_workspace:
     client_id: ...
     client_secret: ...
   ```

   Development may instead use `GOOGLE_WORKSPACE_CLIENT_ID` and
   `GOOGLE_WORKSPACE_CLIENT_SECRET`.

## Authority selection

Users choose `none`, `read`, or `write` independently for Drive, Docs, Sheets,
Slides, Calendar, Gmail, and Meet. OpenID email identity is always requested so
Souls can bind the grant to the correct Google identity.

Drive authority is also an effective floor for Docs, Sheets, and Slides because
Drive scopes grant access to those file types. The UI reflects this implication
and the server recomputes it rather than trusting submitted values.

Calendar write requests `calendar.readonly` plus `calendar.events`. Gmail write
requests `gmail.modify` plus `gmail.send`; Souls does not request the broader
`mail.google.com` scope for new granular connections.

The Google Auth Platform Data Access page must contain the union of every scope
offered by the authority selector. Legacy `read_only` and `full_access` profiles
remain only so authorization callbacks started before the granular migration can
finish safely.

Do not add generic Google Cloud scopes such as `cloud-platform`, `bigquery`, or
`devstorage`; they are unrelated to resident Workspace access.

The Gmail and Drive scopes include restricted scopes. Selecting read-only is not
a low-sensitivity permission.

The narrower `drive.file` scope was not used because it only covers files the
app creates or files a user explicitly opens with the app; it does not provide
general Workspace file access.

Changing authority is revoke-first. A live experiment on August 29, 2026 showed
that revoking one refresh token invalidated every refresh token for the same
Google user and OAuth client. Souls therefore marks the connection
`reauthorizing`, removes its runtime credentials, and reconnects the same
connection row after consent succeeds.

## Testing-mode limitation

Testing mode is suitable for proving the integration with a few named users,
but Google expires refresh tokens after seven days when an external app remains
in Testing and requests scopes beyond basic profile information. Users should
therefore expect to reconnect weekly during the trial.

Before treating the integration as durable, move the consent configuration to
Production and complete whatever verification Google requires for the chosen
restricted scopes. Do not promise persistent unattended Drive access while the
app remains in Testing.

## Runtime use

Once a Google Workspace connection is enabled for a resident:

```sh
helixkit-gws drive files list --params '{"pageSize": 10}'
helixkit-gws drive files --help
```

The helper reads `/run/helixkit/services.yml`, requests a short-lived access
token from the resident-authenticated Souls refresh-broker endpoint, and sets
`GOOGLE_WORKSPACE_CLI_TOKEN` only for the `gws` child process. Neither the
Google client secret nor refresh token is provisioned into the resident
container.
