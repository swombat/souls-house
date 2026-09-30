# Audit Logging

This document describes how audit logging works in the Helix application.

## Overview

Audit logging in Helix tracks significant actions performed by users on business objects like clients, pods, grants, claims, etc. All audit logs are stored in the `audit_logs` table and are associated with the account for proper scoping.

## Architecture

### Database Schema

The `audit_logs` table contains:
- `account_id` - Required. Associates the log with a account
- `user_id` - Optional. The user who performed the action
- `action` - Required. String describing the action (e.g., "create_client", "update_pod")
- `object_type` and `object_id` - Polymorphic association to the object being acted upon
- `data` - JSONB field containing relevant data about the action
- Foreign keys to specific models: `client_id`, `grant_id`, `claim_id`, `project_id`, `enquiry_id`, etc.

### Helper Method

The primary interface for audit logging is the `audit` helper method available in all controllers:

```ruby
def audit(action, object, data = {})
  AuditLog.log(user: current_user, object: object, action: action, data: data)
end
```

## Usage in Controllers

### Basic Usage

In controller actions, call the `audit` helper after successful operations:

```ruby
def create
  respond_to do |format|
    if @client.save
      audit("create_client", @client, params[:client])
      format.html { redirect_to [:account, @client], notice: "Client was successfully created." }
      # ... rest of response handling
    end
  end
end

def update
  respond_to do |format|
    if @client.update(client_params)
      audit("update_client", @client, params[:client])
      format.html { redirect_to [:account, @client], notice: "Client was successfully updated." }
      # ... rest of response handling
    end
  end
end
```

### Destroy Actions

For destroy actions, capture the data before destroying the object:

```ruby
def destroy
  audit("destroy_client", @client, { id: @client.id, name: @client.name })
  @client.destroy
  # ... rest of response handling
end
```

### Bulk Operations

For bulk operations, you can audit with relevant context:

```ruby
def bulk_reassign
  audit("bulk_reassign_clients", nil, {
    client_ids: params[:client_ids],
    from_pod_id: params[:from_pod_id],
    to_pod_id: params[:to_pod_id]
  })
  # ... perform bulk operation
end
```

## Action Naming Conventions

Action names should follow the pattern: `{verb}_{model_name}`

Common verbs:
- `create` - Creating new records
- `update` - Updating existing records
- `destroy` - Deleting records
- `discard` - Soft-deleting records
- `restore` - Restoring soft-deleted records
- `bulk_*` - Bulk operations

Examples:
- `create_client`
- `update_pod`
- `destroy_claim`
- `bulk_reassign_clients`
- `enrich_from_companies_house`

## Data Parameter

The `data` parameter should contain relevant information about the action:

- For create/update actions: Pass the sanitized params hash
- For destroy actions: Pass identifying information like `id` and `name`
- For bulk operations: Pass arrays of IDs and relevant context
- For enrichment operations: Pass source information

## What NOT to Do

❌ **Do not implement audit logging in models**
```ruby
# BAD: Don't do this in models
class Pod < ApplicationRecord
  after_create :log_create_event
  after_update :log_update_event
  
  def log_create_event
    AuditLog.log(user: audit_log_user, object: self, action: "create", data: {})
  end
end
```

❌ **Do not call AuditLog.log directly in controllers**
```ruby
# BAD: Don't do this in controllers
def create
  if @client.save
    AuditLog.log(user: current_user, object: @client, action: "create_client", data: params[:client])
  end
end
```

✅ **Do use the audit helper method**
```ruby
# GOOD: Use the helper method
def create
  if @client.save
    audit("create_client", @client, params[:client])
  end
end
```

## AuditLog Model

The `AuditLog` model handles the complexity of storing audit logs with proper associations:

```ruby
def self.log(user:, object:, action:, data:)
  # If object is nil or not persisted, use the user as the object for audit logging
  audit_object = (object.present? && object.persisted?) ? object : user

  log = self.new(user: user, object: audit_object, action: action, data: data, account: user.account)
  
  # Automatically set foreign keys for associated models
  [:client, :grant, :claim, :enquiry, :enquiry_round, :enquiry_project].each do |relation|
    log.send("#{relation}=", audit_object.send(relation)) if audit_object.respond_to?(relation)
  end
  
  if audit_object.respond_to?(:project) && audit_object.project.is_a?(Project)
    log.project = audit_object.project
  end
  
  log.save!
end
```

## Viewing Audit Logs

Audit logs can be viewed through the admin interface at `/account/accounts/:account_id/audit_logs`. The interface allows filtering by:
- Action type
- User
- Object type
- Date range
- Associated models (client, grant, claim, etc.)

## Security Considerations

- All audit logs are scoped to accounts - users can only see logs for their account
- Audit logs are immutable - they cannot be edited or deleted through the UI
- Sensitive data should not be logged in the `data` field
- The `current_user` is automatically captured, ensuring accountability

## Performance Considerations

- Audit logging is synchronous and happens in the same transaction as the main action
- The `data` field is JSONB, allowing for efficient querying of structured data
- Foreign key indexes are in place for efficient filtering
- Consider the impact on transaction time for bulk operations

## Examples from the Codebase

### Client Controller
```ruby
def create
  if @client.save
    audit("create_client", @client, params[:client])
    # ... response handling
  end
end

def enrich_from_companies_house
  # ... enrichment logic
  audit("enrich_from_companies_house", @client, params[:client])
end
```

### Pod Controller
```ruby
def update
  if @pod.update(pod_params)
    audit("update_pod", @pod, params[:pod])
    # ... response handling
  end
end
```

This system provides comprehensive audit trails while keeping the implementation simple and consistent across the application.
