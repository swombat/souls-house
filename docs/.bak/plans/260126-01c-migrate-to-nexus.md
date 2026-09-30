# Fork HelixKit to Nexus

**Date**: 2026-01-26
**Status**: Final

---

## Part 1: Fork and Minimum Rebrand (30 minutes)

### Repository Setup

```bash
cd ~/dev
git clone git@github.com:swombat/helix_kit.git nexus
cd nexus
git remote rename origin upstream
git remote add origin git@github.com:swombat/nexus.git
git push -u origin master
```

### Required File Changes

Only these four files must change to deploy:

**`config/application.rb`**
```ruby
module Nexus
  class Application < Rails::Application
```

**`config/database.yml`**
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
```

**`config/deploy.yml`**
```yaml
service: nexus
image: dtenner/nexus

proxy:
  host: nexus.swombat.io

builder:
  cache:
    image: dtenner/nexus:production-build-cache

accessories:
  postgres:
    env:
      clear:
        POSTGRES_USER: nexus
        POSTGRES_DB: nexus_production
```

**`.kamal/secrets`**
```bash
DATABASE_URL="postgres://nexus:$(cat config/credentials/deployment/postgres_pw_prod.key)@nexus-postgres:5432/nexus_production"
```

### Verify Locally

```bash
rails db:create db:migrate
bin/dev
# Verify app works at localhost:3100
```

### Commit

```bash
git commit -am "Rebrand to Nexus"
git push
```

---

## Part 2: Deploy (when ready, 1-2 hours)

### Prerequisites

- [ ] Create GitHub repo `swombat/nexus` (empty, no README)
- [ ] Create DNS A record: `nexus.swombat.io` -> `95.217.118.47`
- [ ] Wait for DNS propagation: `dig nexus.swombat.io`

### Credentials

```bash
rm config/credentials/production.yml.enc config/credentials/production.key
EDITOR=vim rails credentials:edit -e production

mkdir -p config/credentials/deployment
openssl rand -base64 32 > config/credentials/deployment/postgres_pw_prod.key
```

### Deploy

```bash
kamal setup
curl https://nexus.swombat.io/up
```

---

## Part 3: Data Migration (optional)

**Decision point**: Does Nexus need HelixKit's existing data, or should it start fresh?

### Option A: Fresh Start

```bash
kamal app exec -r web "bin/rails db:seed"
# Create new admin user via console or signup
```

### Option B: Migrate Data

```bash
# On server (ssh swombat@95.217.118.47 -p 12222)
docker exec helix-kit-postgres pg_dump -U helix_kit helix_kit_production > /tmp/export.sql
docker cp helix-kit-postgres:/tmp/export.sql /tmp/
docker cp /tmp/export.sql nexus-postgres:/tmp/
docker exec nexus-postgres psql -U nexus nexus_production < /tmp/export.sql

# Create auxiliary databases
docker exec nexus-postgres createdb -U nexus nexus_production_cache
docker exec nexus-postgres createdb -U nexus nexus_production_queue
docker exec nexus-postgres createdb -U nexus nexus_production_cable

# Cleanup
rm /tmp/export.sql
```

### Verify

```bash
kamal app exec -r web "bin/rails db:migrate:status"
# Log in with existing credentials
```

---

## Upstream Sync (when needed)

```bash
git fetch upstream
git log HEAD..upstream/master --oneline
git merge upstream/master
# Resolve conflicts in branded files
git push origin master
```

Expected conflict files: `application.rb`, `deploy.yml`, `database.yml`, `.kamal/secrets`
