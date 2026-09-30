# Fork HelixKit to Create Nexus Application

**Date**: 2026-01-26
**Status**: Ready for implementation
**Complexity**: High - involves repository management, data migration, and full rebranding

## Executive Summary

This plan details the process of forking HelixKit into a new "Nexus" application while maintaining the ability to pull upstream improvements from HelixKit. The migration involves:

1. Creating a new GitHub repository from the existing codebase
2. Setting up git remotes for upstream synchronization
3. Rebranding all user-facing elements (name, logo, colors, domain)
4. Configuring parallel deployment on the same physical server
5. Migrating production data from HelixKit to Nexus
6. Setting up separate credentials and services

Both applications will continue to run on the same server (95.217.118.47), with HelixKit remaining as a generic starter template and Nexus becoming a specialized application.

---

## Architecture Overview

### Current State (HelixKit)
```
Repository: github.com/swombat/helix_kit
Domain: helix-kit.granttree.co.uk
Database: helix_kit_production (+ _cache, _queue, _cable)
Docker Image: dtenner/helix-kit
Service Name: helix-kit
Port: 3000 (internal)
```

### Target State (Nexus)
```
Repository: github.com/swombat/nexus (new)
Domain: nexus.swombat.io
Database: nexus_production (+ _cache, _queue, _cable)
Docker Image: dtenner/nexus
Service Name: nexus
Port: 3000 (internal, different container)
```

### Upstream Sync Strategy
```
nexus/
  └── remotes/
      ├── origin     → github.com/swombat/nexus (push/pull)
      └── upstream   → github.com/swombat/helix_kit (pull only)
```

---

## Implementation Plan

### Phase 1: Repository Setup

#### 1.1 Create New GitHub Repository
- [ ] Go to GitHub and create a new **empty** repository named `nexus` (do NOT initialize with README)
- [ ] Note: GitHub doesn't allow forking your own repo, so we create a fresh repo and push

#### 1.2 Clone and Configure Remotes
```bash
# Clone HelixKit to a new directory
cd ~/dev
git clone git@github.com:swombat/helix_kit.git nexus
cd nexus

# Rename origin to upstream (for pulling HelixKit updates)
git remote rename origin upstream

# Add new origin pointing to Nexus repo
git remote add origin git@github.com:swombat/nexus.git

# Verify remotes
git remote -v
# Should show:
# origin    git@github.com:swombat/nexus.git (fetch)
# origin    git@github.com:swombat/nexus.git (push)
# upstream  git@github.com:swombat/helix_kit.git (fetch)
# upstream  git@github.com:swombat/helix_kit.git (push)

# Push all branches and tags to new origin
git push -u origin master
git push origin --all
git push origin --tags
```

#### 1.3 Configure Upstream Sync Workflow
- [ ] Create a documented process for syncing upstream changes:

```bash
# To pull upstream HelixKit changes into Nexus:
git fetch upstream
git checkout master
git merge upstream/master
# Resolve any conflicts, particularly in branded files
git push origin master
```

- [ ] Consider creating a `SYNCING.md` document in Nexus explaining this process

---

### Phase 2: Rebranding

#### 2.1 Application Name Changes

**File: `/config/application.rb`**
- [ ] Change module name from `HelixKit` to `Nexus`

```ruby
# Before
module HelixKit
  class Application < Rails::Application

# After
module Nexus
  class Application < Rails::Application
```

**File: `/config/database.yml`**
- [ ] Update all database names:

```yaml
development:
  primary:
    database: nexus_development
  cache:
    database: nexus_development_cache
  queue:
    database: nexus_development_queue
  cable:
    database: nexus_development_cable

test:
  database: nexus_test

# Production uses DATABASE_URL from environment
```

#### 2.2 Frontend Branding

**Files to update:**
- [ ] `/app/frontend/lib/components/misc/HelixKitLogo.svelte` - Rename to `NexusLogo.svelte`
- [ ] `/app/frontend/lib/components/misc/HelixLogo.svelte` - Rename to `NexusLogo.svelte` (or remove if duplicate)
- [ ] `/app/assets/images/helix-kit-logo.svg` - Replace with Nexus logo
- [ ] `/app/assets/images/helix-logo.svg` - Replace with Nexus logo

**Update all imports:**
- [ ] `/app/frontend/lib/components/navigation/navbar.svelte`:
  ```svelte
  // Before
  import Logo from '$lib/components/misc/HelixKitLogo.svelte';

  // After
  import Logo from '$lib/components/misc/NexusLogo.svelte';
  ```

**Update navbar fallback text:**
- [ ] In `navbar.svelte`, change fallback from `'HelixKit'` to `'Nexus'`:
  ```svelte
  <span class="hidden sm:inline">{siteSettings?.site_name || 'Nexus'}</span>
  ```

#### 2.3 Homepage Updates

**File: `/app/frontend/pages/home.svelte`**
- [ ] Update the entire homepage content - this is HelixKit's feature showcase
- [ ] Replace with Nexus-specific content (can be placeholder initially)
- [ ] Update GitHub URL from `'https://github.com/swombat/helix_kit'` to appropriate Nexus URL or remove
- [ ] Update `<title>` and hero text

#### 2.4 Email Templates

**File: `/app/mailers/application_mailer.rb`**
- [ ] Change default from address:
  ```ruby
  # Before
  default from: "helix-kit@granttree.co.uk"

  # After
  default from: "nexus@swombat.io"
  ```

**Email template files to update:**
- [ ] `/app/views/user_mailer/confirmation.html.erb` - Change "Welcome to Helix Kit!" and "The Helix Kit Team"
- [ ] `/app/views/user_mailer/confirmation.text.erb` - Same changes
- [ ] `/app/views/account_mailer/confirmation.html.erb` - Update branding
- [ ] `/app/views/account_mailer/confirmation.text.erb` - Update branding
- [ ] `/app/views/account_mailer/team_invitation.html.erb` - Update branding
- [ ] `/app/views/account_mailer/team_invitation.text.erb` - Update branding
- [ ] `/app/views/passwords_mailer/reset.html.erb` - Update branding
- [ ] `/app/views/passwords_mailer/reset.text.erb` - Update branding

#### 2.5 Documentation Updates

**Files to update:**
- [ ] `/README.md` - Complete rewrite for Nexus
- [ ] `/CLAUDE.md` - Update project name references
- [ ] `/AGENTS.md` - Update project name references
- [ ] `/docs/overview.md` - Update "Helix Kit" references
- [ ] `/docs/database-backup.md` - Update example filenames

#### 2.6 Layout and Meta Tags

**File: `/app/views/layouts/application.html.erb`**
- [ ] Update default title:
  ```erb
  <title><%= content_for(:title) || "Nexus" %></title>
  ```

#### 2.7 Color Scheme (Optional - can defer)

**File: `/app/frontend/entrypoints/application.css`**
- [ ] Update CSS custom properties if Nexus needs different colors
- [ ] Current colors are neutral grayscale; customize `--primary`, `--accent`, etc. as needed

---

### Phase 3: Deployment Configuration

#### 3.1 Create Kamal Deploy Configuration

**File: `/config/deploy.yml`**
- [ ] Update completely for Nexus:

```yaml
service: nexus
image: dtenner/nexus

registry:
  username: dtenner
  password:
  - KAMAL_REGISTRY_PASSWORD

ssh:
  user: swombat
  port: 12222

env:
  clear:
    RAILS_SERVE_STATIC_FILES: true
    RAILS_LOG_TO_STDOUT: true
    RAILS_ENV: production
  secret:
    - RAILS_MASTER_KEY
    - DATABASE_URL

servers:
  web:
    hosts:
      - 95.217.118.47
  jobs:
    hosts:
      - 95.217.118.47
    cmd: "./bin/rails solid_queue:start"

proxy:
  ssl: true
  host: nexus.swombat.io
  app_port: 3000

builder:
  arch: amd64
  remote: ssh://swombat@95.217.118.47:12222
  args:
    RAILS_ENV: production
  cache:
    type: registry
    options: mode=max
    image: dtenner/nexus:production-build-cache

accessories:
  postgres:
    image: postgres:16.2
    host: 95.217.118.47
    env:
      clear:
        POSTGRES_USER: nexus
        POSTGRES_DB: nexus_production
      secret:
        - POSTGRES_PASSWORD
    directories:
      - data:/var/lib/postgresql/data
```

#### 3.2 Create Kamal Secrets File

**File: `/.kamal/secrets`**
- [ ] Create new secrets file:

```bash
RAILS_MASTER_KEY=$(cat config/credentials/production.key)
KAMAL_REGISTRY_PASSWORD=$(cat config/credentials/deployment/kamal_password.key)
POSTGRES_PASSWORD=$(cat config/credentials/deployment/postgres_pw_prod.key)
DATABASE_URL="postgres://nexus:$(cat config/credentials/deployment/postgres_pw_prod.key)@nexus-postgres:5432/nexus_production"
```

Note: Initially can reuse the same `kamal_password.key`, but should create new `postgres_pw_prod.key` for Nexus.

#### 3.3 Production Environment Configuration

**File: `/config/environments/production.rb`**
- [ ] Update mailer host:
  ```ruby
  config.action_mailer.default_url_options = { host: "nexus.swombat.io" }
  ```
- [ ] Update default from address if using credentials:
  ```ruby
  config.action_mailer.default_options = { from: "nexus@#{Rails.application.credentials.dig(:mailgun, :domain)}" }
  ```

---

### Phase 4: Credentials Setup

#### 4.1 Generate New Production Credentials

- [ ] Generate new master key and credentials file:
```bash
# Remove existing production credentials (we'll create new ones)
rm config/credentials/production.yml.enc
rm config/credentials/production.key

# Generate new production credentials
EDITOR="code --wait" rails credentials:edit --environment production
```

- [ ] Add required credentials:
```yaml
aws:
  access_key_id: <SAME_AS_HELIXKIT_INITIALLY>
  secret_access_key: <SAME_AS_HELIXKIT_INITIALLY>
  s3_region: eu-north-1
  s3_bucket: <NEW_NEXUS_BUCKET_OR_SAME>
  postgres_bucket: <NEW_NEXUS_BACKUP_BUCKET>

ai:
  openrouter:
    api_token: <SAME_AS_HELIXKIT>
  # Add other AI providers as needed

mailgun:
  domain: swombat.io  # Or configure new domain
  smtp_server: smtp.mailgun.org
  smtp_port: 587
  smtp_login: <CONFIGURE>
  smtp_password: <CONFIGURE>

honeybadger:
  api_key: <NEW_HONEYBADGER_PROJECT_KEY>
```

#### 4.2 Create New Deployment Credentials

- [ ] Create new PostgreSQL password for Nexus:
```bash
mkdir -p config/credentials/deployment
# Generate a secure password
openssl rand -base64 32 > config/credentials/deployment/postgres_pw_prod.key
```

- [ ] Can reuse Docker Hub credentials initially (same `kamal_password.key`)

---

### Phase 5: Database Migration

#### 5.1 Pre-Migration Preparation

- [ ] Ensure HelixKit production is stable and no active writes
- [ ] Create a fresh backup of HelixKit production:
```bash
# On the server or via Kamal
kamal app exec -r web "bin/rails runner 'DatabaseBackupJob.perform_now'"
```

- [ ] Note the backup filename for reference

#### 5.2 Export HelixKit Database

```bash
# SSH to the server
ssh swombat@95.217.118.47 -p 12222

# Enter the HelixKit postgres container
docker exec -it helix-kit-postgres bash

# Create a dump (inside container)
pg_dump -U helix_kit -d helix_kit_production > /var/lib/postgresql/data/helix_kit_export.sql

# Exit container
exit

# Copy dump to host filesystem
docker cp helix-kit-postgres:/var/lib/postgresql/data/helix_kit_export.sql ~/helix_kit_export.sql
```

#### 5.3 Deploy Nexus Infrastructure (Database Only First)

```bash
# From local Nexus repo
kamal accessory boot postgres
```

This creates the `nexus-postgres` container with empty database.

#### 5.4 Import Data to Nexus

```bash
# SSH to server
ssh swombat@95.217.118.47 -p 12222

# Copy export into Nexus postgres container
docker cp ~/helix_kit_export.sql nexus-postgres:/var/lib/postgresql/data/

# Enter Nexus postgres container
docker exec -it nexus-postgres bash

# Import the data
psql -U nexus -d nexus_production < /var/lib/postgresql/data/helix_kit_export.sql

# Create the auxiliary databases
createdb -U nexus nexus_production_cache
createdb -U nexus nexus_production_queue
createdb -U nexus nexus_production_cable

# Clean up
rm /var/lib/postgresql/data/helix_kit_export.sql
exit

# Clean up on host
rm ~/helix_kit_export.sql
```

#### 5.5 Run Migrations

```bash
# Deploy the full Nexus app
kamal deploy

# The docker-entrypoint will run db:prepare automatically
# But verify migrations are current:
kamal app exec -r web "bin/rails db:migrate:status"
```

---

### Phase 6: DNS and SSL Configuration

#### 6.1 DNS Setup

- [ ] Add DNS A record for `nexus.swombat.io` pointing to `95.217.118.47`
- [ ] Wait for DNS propagation (check with `dig nexus.swombat.io`)

#### 6.2 SSL Certificate

Kamal's proxy (kamal-proxy) handles SSL automatically via Let's Encrypt when:
- DNS is properly configured
- Port 80 is accessible for ACME challenge

- [ ] Verify SSL certificate is issued after first deploy:
```bash
curl -I https://nexus.swombat.io/up
```

---

### Phase 7: Verification and Testing

#### 7.1 Basic Health Checks

- [ ] Verify app is running:
```bash
curl https://nexus.swombat.io/up
# Should return 200 OK
```

- [ ] Verify Kamal status:
```bash
kamal app details
```

#### 7.2 Data Verification

- [ ] Log in with existing user credentials
- [ ] Verify user data migrated correctly:
  - User accounts exist
  - Account memberships preserved
  - Chats and messages present
  - Agents configured correctly
  - Whiteboards contain expected data

- [ ] Verify settings migrated:
```bash
kamal app exec -r web "bin/rails runner 'puts Setting.all.map { |s| [s.key, s.value] }.to_h'"
```

#### 7.3 Feature Testing

- [ ] Test authentication flow (login/logout)
- [ ] Test chat functionality
- [ ] Test agent conversations
- [ ] Test file uploads (Active Storage)
- [ ] Test email sending (use test account)

#### 7.4 Background Jobs

- [ ] Verify Solid Queue is running:
```bash
kamal app logs -r jobs | tail -50
```

- [ ] Verify scheduled jobs are registered:
```bash
kamal app exec -r web "bin/rails runner 'puts SolidQueue::RecurringTask.all.map(&:key)'"
```

#### 7.5 Monitoring

- [ ] Verify Honeybadger is receiving data (if configured)
- [ ] Check logs for errors:
```bash
kamal app logs -r web | grep -i error
```

---

### Phase 8: Cleanup and Documentation

#### 8.1 Update Site Settings

- [ ] Log in as site admin
- [ ] Navigate to Admin > Site Settings
- [ ] Update:
  - Site Name: "Nexus"
  - Any other configurable branding

#### 8.2 Create SYNCING.md

- [ ] Document the upstream sync process in `/SYNCING.md`:

```markdown
# Syncing with HelixKit Upstream

This project was forked from HelixKit and maintains an upstream connection
for pulling generic improvements.

## Remotes

- `origin`: github.com/swombat/nexus (our repo)
- `upstream`: github.com/swombat/helix_kit (template repo)

## Pulling Upstream Changes

1. Fetch upstream changes:
   ```bash
   git fetch upstream
   ```

2. Review what's new:
   ```bash
   git log HEAD..upstream/master --oneline
   ```

3. Merge upstream into your branch:
   ```bash
   git checkout master
   git merge upstream/master
   ```

4. Resolve conflicts (expected in branded files):
   - config/application.rb
   - config/deploy.yml
   - app/frontend/pages/home.svelte
   - Email templates
   - README.md

5. Test locally, then push:
   ```bash
   git push origin master
   ```

## Files That Will Always Conflict

These files have Nexus-specific changes and will need manual resolution:
- config/application.rb (module name)
- config/deploy.yml (service name, domain, image)
- config/database.yml (database names)
- app/mailers/application_mailer.rb (from address)
- All email templates (branding)
- app/frontend/pages/home.svelte (homepage content)
- README.md (project description)
```

#### 8.3 Git Ignore Updates

- [ ] Ensure `.gitignore` includes:
```
config/credentials/deployment/*.key
.kamal/secrets-*
```

---

## Rollback Plan

### If Nexus deployment fails:

1. **Stop Nexus services**:
```bash
cd ~/dev/nexus
kamal app stop
```

2. **Remove Nexus containers**:
```bash
kamal app remove
kamal accessory remove postgres
```

3. **Verify HelixKit still operational**:
```bash
curl https://helix-kit.granttree.co.uk/up
```

### If data migration corrupts data:

1. **HelixKit data is unchanged** - the export was a copy, not a move
2. **Re-run migration** from fresh HelixKit export if needed
3. **Restore from S3 backup** if HelixKit also has issues:
```bash
aws s3 cp s3://your-bucket/helix_kit_production_YYYY-MM-DD_HH-MM-SS.sql.gz ./backup.sql.gz
gunzip backup.sql.gz
# Import as needed
```

---

## Post-Migration Tasks (Future)

These are not blocking but should be done eventually:

### Separate Credentials
- [ ] Create new Honeybadger project for Nexus
- [ ] Create new S3 bucket for Nexus file uploads
- [ ] Create new S3 bucket for Nexus database backups
- [ ] Set up separate Mailgun domain/configuration
- [ ] Create new OpenRouter API key (for usage tracking)

### Monitoring Setup
- [ ] Set up uptime monitoring for nexus.swombat.io
- [ ] Configure Honeybadger alerts

### HelixKit Cleanup
- [ ] Reset HelixKit database to demo state (after confirming Nexus is stable)
- [ ] Update HelixKit documentation to reference Nexus as a "production use" example

---

## Files Changed Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `config/application.rb` | Modify | Module name |
| `config/database.yml` | Modify | Database names |
| `config/deploy.yml` | Modify | Service name, domain, image |
| `config/environments/production.rb` | Modify | Mailer host |
| `.kamal/secrets` | Modify | Database URL, service names |
| `app/mailers/application_mailer.rb` | Modify | From address |
| `app/frontend/lib/components/misc/HelixKitLogo.svelte` | Rename | To NexusLogo.svelte |
| `app/frontend/lib/components/navigation/navbar.svelte` | Modify | Logo import, fallback text |
| `app/frontend/pages/home.svelte` | Modify | Complete content rewrite |
| `app/assets/images/helix-kit-logo.svg` | Replace | New Nexus logo |
| `app/assets/images/helix-logo.svg` | Replace | New Nexus logo |
| `app/views/layouts/application.html.erb` | Modify | Default title |
| `app/views/user_mailer/*.erb` | Modify | Branding text |
| `app/views/account_mailer/*.erb` | Modify | Branding text |
| `app/views/passwords_mailer/*.erb` | Modify | Branding text |
| `README.md` | Modify | Complete rewrite |
| `CLAUDE.md` | Modify | Project name references |
| `SYNCING.md` | Create | Upstream sync documentation |
| `config/credentials/production.yml.enc` | Create | New encrypted credentials |
| `config/credentials/production.key` | Create | New master key |

---

## External Dependencies

No new npm packages or Ruby gems are required for this migration. The tech stack remains identical.

---

## Estimated Time

| Phase | Duration |
|-------|----------|
| Phase 1: Repository Setup | 15 minutes |
| Phase 2: Rebranding | 1-2 hours |
| Phase 3: Deployment Configuration | 30 minutes |
| Phase 4: Credentials Setup | 30 minutes |
| Phase 5: Database Migration | 1 hour |
| Phase 6: DNS/SSL | 30 minutes (+ propagation) |
| Phase 7: Verification | 1 hour |
| Phase 8: Cleanup | 30 minutes |

**Total: 5-7 hours** (not counting DNS propagation wait time)

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| DNS propagation delays | Medium | Low | Plan for 24-48hr wait; can verify locally first |
| Database export/import issues | Low | High | Multiple backups exist; HelixKit data unchanged |
| Credential misconfiguration | Medium | Medium | Test in development first; can reuse HelixKit creds initially |
| Port conflicts on server | Low | Medium | Kamal proxy handles routing by domain; containers are isolated |
| Upstream merge conflicts | High (expected) | Low | Document expected conflicts; merge regularly |
