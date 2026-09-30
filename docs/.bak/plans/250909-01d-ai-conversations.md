# AI Conversations Implementation Plan (Backend Implementation)

## Executive Summary

This document tracks the backend Rails implementation for the AI chat feature according to the specification.

## Backend Implementation Tasks

### Phase 1: Update Navigation

- [x] Add "Chats" menu item to navigation

### Phase 2: Enhance Models with Business Logic

- [x] Update `/app/models/chat.rb` with business logic and as_json serialization
- [x] Update `/app/models/message.rb` with formatting methods and as_json serialization
- [x] Fix model_name conflict by renaming to ai_model_name
- [x] Add redcarpet gem for markdown rendering

### Phase 3: Update Controllers

- [x] Update `/app/controllers/chats_controller.rb` with proper props and actions
- [x] Update `/app/controllers/messages_controller.rb` with retry action

### Phase 4: Update Routes

- [x] Add retry route for messages

### Phase 5: Test Implementation

- [x] Run rails test to verify all changes work
- [x] All model tests passing
- [x] All controller tests passing
- [x] Fixed Current.user vs current_user issue
- [x] Added back file attachment support to messages

## Implementation Notes

Following Rails conventions throughout:
- Fat models, skinny controllers
- Using custom as_json methods instead of json_attributes (to avoid conflicts)
- Server-side markdown rendering and date formatting via Redcarpet
- Proper association-based authorization
- RESTful routes and actions
- Fixed model_name conflict by renaming to ai_model_name

## Key Issues Resolved

1. **model_name method conflict**: Renamed to `ai_model_name` to avoid Rails internal conflicts
2. **JsonAttributes concern issues**: Used custom `as_json` methods instead for simpler, cleaner implementation
3. **Current.user vs current_user**: Used `Current.user` pattern consistent with the app
4. **Redcarpet dependency**: Added gem to Gemfile for markdown rendering
5. **File attachments**: Preserved existing file attachment functionality in messages

## Ready for Frontend Implementation

All backend Rails changes are complete and tested. The API is ready to support the frontend Svelte components as specified in the original plan.
