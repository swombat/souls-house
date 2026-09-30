# Chat Archive and Soft Delete Implementation Plan

## Overview
Implement archive and soft delete (discard) functionality for the Chat model using the Discard gem.

## Tasks

- [x] 1. Install the Discard gem
  - Add `gem 'discard', '~> 1.3'` to Gemfile
  - Run `bundle install`

- [x] 2. Create migration for new columns
  - Add `discarded_at` (datetime, null, indexed)
  - Add `archived_at` (datetime, null, indexed)

- [x] 3. Update Chat model
  - Include `Discard::Model`
  - Add scopes: `kept`, `archived`, `active`
  - Add methods: `archive!`, `unarchive!`, `archived?`, `respondable?`
  - Update `json_attributes` to include new attributes

- [x] 4. Update ChatsController
  - Add `archive` action
  - Add `unarchive` action
  - Add `discard` action (soft delete with admin authorization)
  - Add `restore` action (admin only)
  - Update `index` action to show active first, then archived

- [x] 5. Update routes
  - Add member routes for archive, unarchive, discard, restore

- [x] 6. Write model tests
  - Test archive/unarchive methods
  - Test archived? method
  - Test respondable? method
  - Test scopes

- [x] 7. Write controller tests
  - Test archive action
  - Test unarchive action
  - Test discard action (admin authorization)
  - Test restore action (admin authorization)
  - Test index action ordering

- [x] 8. Run migration and verify tests pass

## Notes
- Following Rails conventions with fat models, skinny controllers
- Using Discard gem for soft delete (standard Rails Way approach)
- Authorization: any member can archive, only admins can discard/restore
