# Svelte Refactoring Review

Date: 2026-05-03

Status: Review plan only. No refactoring has been performed.

## Goal

Reduce the sprawl in app-owned Svelte files while keeping the Inertia page metaphor intact. Pages should remain recognizable as pages: they receive server props, subscribe to page-level data, coordinate high-level flows, and compose smaller pieces. They should not become tiny routers around a maze of opaque components.

The extraction target is the repeated or independently testable work currently embedded inside pages: tab bodies, drawers, cards, lists, modal forms, URL/filter state, optimistic UI logic, and shared formatting helpers.

## Scope

Reviewed app-owned Svelte files under:

- `app/frontend/pages`
- `app/frontend/layouts`
- `app/frontend/lib/components`, excluding generated shadcn primitives

Out of scope for this plan:

- `app/frontend/lib/components/shadcn/**`: generated/vendor-style primitives. Leave them alone unless upgrading shadcn.
- `app/frontend/test/__mocks__/Link.svelte`: test fixture.

## Current Shape

The Svelte layer is already halfway through a healthy refactor. Chat state has several tested plain JS helpers:

- `app/frontend/lib/chat-message-state.js`
- `app/frontend/lib/chat-streaming-state.js`
- `app/frontend/lib/chat-sync-subscriptions.js`
- `app/frontend/lib/chat-message-formatting.js`
- `app/frontend/lib/file-upload-rules.js`

That is the right direction. The next pass should do the same for other domains: keep domain logic testable in plain JS where possible, and make Svelte components mostly responsible for rendering and local interaction.

## Refactoring Rules

1. Keep pages as orchestration boundaries.
  A page should still show the page structure at a glance: page header, major regions, forms/dialogs, and route submissions.
2. Extract sections, not everything.
  Good extraction candidates are repeated panels, tab bodies, modal bodies, list rows, filter bars, and self-contained widgets.
3. Move pure logic to JS modules before moving markup.
  Filtering, grouping, token warning levels, icon lookup, form defaults, URL param serialization, and formatting helpers should be ordinary functions with Vitest coverage.
4. Prefer existing Rails/Inertia route helpers.
  Several components still use literal paths. When touching them, use generated route helpers where they exist, and keep route ownership obvious.
5. Do not fight shadcn.
  Components can wrap shadcn primitives for app-specific patterns, but should not fork the primitives.
6. Add tests where extraction creates a natural boundary.
  Component tests are useful for widgets, but the highest-value tests here are plain JS tests for logic extracted from pages.

## Priority Order

### P0 - First Refactoring Slice

These files carry multiple responsibilities and should be tackled first.

1. `app/frontend/pages/agents/edit.svelte` - 960 lines
  Most egregious page. It contains tab navigation, five tab bodies, form defaults, model lookup, tool toggling, Telegram actions, memory filtering, memory creation, memory refinement, and memory card rendering.
2. `app/frontend/pages/documentation.svelte` - 1030 lines
  Largest file. It is mostly content and code examples, so it is less behaviorally risky than the agent editor, but it is structurally the least maintainable.
3. `app/frontend/pages/chats/show.svelte` - 870 lines
  Already improved by tested helper modules and chat components, but still owns message pagination, sync, streaming, scroll behavior, retries, editing, deletion, voice, dialogs, toasts, and composition.
4. `app/frontend/pages/agents/index.svelte` - 530 lines
  Combines agent cards, create form, upgrade modal, model/tool/color/icon selectors, icon registry, and actions. It also duplicates logic from the edit page.
5. `app/frontend/pages/admin/audit-logs.svelte` - 478 lines
  Filter parsing/serialization, multi-select rendering, date range UI, table rows, drawer detail sections, JSON highlighting, and sync all live in one file.
6. `app/frontend/pages/chats/new.svelte` - 403 lines
  Duplicates agent icon registry and model/agent selection with other chat/agent screens. It also contains chat composer-like behavior that overlaps with `MessageComposer`.
7. `app/frontend/lib/components/navigation/navbar.svelte` - 397 lines
  This is a global component, but it has page-level complexity: public nav, desktop nav, mobile menu, admin menu, account switcher, integrations menu, user menu, search, logout, and theme persistence.
8. `app/frontend/lib/components/chat/ChatHeader.svelte` - 385 lines
  It is already a component, but it is too broad. Title editing, token display, chat actions, admin actions, moderation, archive/delete, fork, web access, and dialog triggers are independent concerns.

### P1 - Second Slice

These are not as severe, but they would become cleaner once the P0 shared components exist.

- `app/frontend/pages/accounts/show.svelte` - 339 lines
- `app/frontend/pages/chats/ChatList.svelte` - 303 lines
- `app/frontend/pages/home.svelte` - 299 lines
- `app/frontend/pages/whiteboards/index.svelte` - 263 lines
- `app/frontend/pages/accounts/convert_confirmation.svelte` - 251 lines
- `app/frontend/lib/components/chat/MessageBubble.svelte` - 243 lines
- `app/frontend/pages/admin/accounts.svelte` - 238 lines
- `app/frontend/lib/components/chat/AgentTriggerBar.svelte` - 181 lines
- `app/frontend/lib/components/chat/WhiteboardDrawer.svelte` - 180 lines
- `app/frontend/lib/components/chat/MessageComposer.svelte` - 168 lines
- `app/frontend/pages/admin/settings.svelte` - 158 lines
- `app/frontend/lib/components/AvatarUpload.svelte` - 157 lines

### P2 - Opportunistic Cleanup

These are small enough to leave alone until nearby work touches them, except where they duplicate a new shared component.

- Integration pages: GitHub, Oura, X, GitHub repo selection
- API key pages
- Auth/password/registration pages
- Form wrapper components
- Small chat widgets such as file attachment, toast, image lightbox, debug panel
- Layouts and logos

## Proposed Shared Extracts

### Agent UI

Create an agent component/helper area:

- `app/frontend/lib/components/agents/AgentCard.svelte`
- `app/frontend/lib/components/agents/AgentFormFields.svelte`
- `app/frontend/lib/components/agents/AgentModelSelect.svelte`
- `app/frontend/lib/components/agents/AgentToolChecklist.svelte`
- `app/frontend/lib/components/agents/AgentAppearanceFields.svelte`
- `app/frontend/lib/components/agents/AgentMemoryPanel.svelte`
- `app/frontend/lib/components/agents/AgentMemoryCard.svelte`
- `app/frontend/lib/components/agents/AgentMemoryFilters.svelte`
- `app/frontend/lib/components/agents/AgentTelegramPanel.svelte`
- `app/frontend/lib/components/agents/AgentUpgradeDialog.svelte`
- `app/frontend/lib/agent-icons.js`
- `app/frontend/lib/agent-models.js`
- `app/frontend/lib/agent-memory.js`

High-value tests:

- `agent-models.test.js`: model grouping, label lookup, thinking support.
- `agent-memory.test.js`: filtering, journal opacity, token summary display values.
- `agent-icons.test.js`: accepted icon lookup/fallback.

### Chat UI

Keep `pages/chats/show.svelte` as the chat room orchestrator, but extract the remaining page internals:

- `app/frontend/lib/components/chat/MessageList.svelte`
- `app/frontend/lib/components/chat/MessageTimestampDivider.svelte`
- `app/frontend/lib/components/chat/ChatStatusPlaceholders.svelte`
- `app/frontend/lib/components/chat/TokenWarningBanner.svelte`
- `app/frontend/lib/components/chat/ChatDialogs.svelte`
- `app/frontend/lib/components/chat/ChatSidebarFilters.svelte`
- `app/frontend/lib/chat-pagination-state.js`
- `app/frontend/lib/chat-scroll-state.js`
- `app/frontend/lib/chat-actions.js` where shared route/fetch helpers make sense.

High-value tests:

- Pagination merge/dedupe and oldest-id handling.
- Scroll threshold decisions without DOM.
- Token warning level calculation reused by page and header.

### Admin Tables

Create reusable admin/table pieces:

- `app/frontend/lib/components/admin/ResourceSplitView.svelte`
- `app/frontend/lib/components/admin/AuditLogFilters.svelte`
- `app/frontend/lib/components/admin/AuditLogTable.svelte`
- `app/frontend/lib/components/admin/AuditLogDrawer.svelte`
- `app/frontend/lib/components/admin/AuditLogDetailSection.svelte`
- `app/frontend/lib/components/admin/AccountList.svelte`
- `app/frontend/lib/components/admin/AccountDetails.svelte`
- `app/frontend/lib/admin-audit-log-filters.js`

High-value tests:

- Audit filter initialization from query props.
- Audit filter URL serialization, including empty filter removal.
- Account search matching.

### Settings/Integrations

The GitHub, Oura, and X pages repeat a lot of connection-status structure.

Create:

- `app/frontend/lib/components/settings/IntegrationPage.svelte`
- `app/frontend/lib/components/settings/IntegrationStatusCard.svelte`
- `app/frontend/lib/components/settings/IntegrationSettingsCard.svelte`
- `app/frontend/lib/integration-actions.js`

Keep each page as the page, passing provider-specific copy, icon, routes, and enabled setting payload.

### General UI

Create a few app-level components only where they remove repeated code:

- `PageHeader.svelte`: title, subtitle, optional actions.
- `EmptyState.svelte`: icon, title, body, optional action.
- `DataListShell.svelte`: split list/detail page shell.
- `FlashMessages.svelte`: success/notice/alert rendering from `$page.props.flash`.
- `CodeBlock.svelte`: highlight wrapper used by documentation and audit logs.

Avoid creating a generic `FormField` abstraction unless repetition becomes real after the first pass. Many current fields are different enough that a generic wrapper may make them harder to read.

## File-by-File Evaluation

### Pages

#### `app/frontend/pages/documentation.svelte`

Problem:

- Giant content file with many inline code example constants.
- Page markup, navigation/sections, code block rendering, and documentation content are inseparable.
- Editing any single documentation section requires scrolling through the whole file.

Plan:

- Extract code examples to `app/frontend/lib/documentation-examples.js`.
- Extract `DocumentationSection.svelte`, `DocumentationCodeBlock.svelte`, and maybe `FeatureDocCard.svelte`.
- Keep the page as the table of contents and section ordering.
- Add a small test for example exports if they are transformed or indexed; otherwise no test needed.

Priority: P0 because of size and editing friction, despite low runtime complexity.

#### `app/frontend/pages/agents/edit.svelte`

Problem:

- The page is doing everything: tab system, form setup, model/tool helpers, Telegram actions, memory CRUD, memory filtering, refinement menu, and all tab markup.
- It duplicates model/tool/color/icon concepts with `agents/index.svelte` and chat creation.
- Memory filtering and opacity are testable logic but live inside the page.

Plan:

- Keep the page responsible for receiving props, creating the Inertia form, saving the agent, and deciding active tab.
- Extract tab navigation to `AgentEditTabs.svelte`.
- Extract tab bodies: `AgentIdentityTab`, `AgentAppearanceTab`, `AgentModelTab`, `AgentIntegrationsTab`, `AgentMemoryTab`.
- Extract memory helpers to `agent-memory.js`.
- Extract model helpers to `agent-models.js`.
- Extract reusable `AgentModelSelect` and `AgentToolChecklist`.
- Replace the custom refinement dropdown with the existing dropdown menu primitives.
- After extraction, the page should read as form setup plus tab composition.

Priority: P0, first target.

#### `app/frontend/pages/chats/show.svelte`

Problem:

- The page has already had logic pulled into tested helpers, but it still contains too many independent workflows.
- Message pagination, scroll preservation, streaming safety refresh, transient toasts, retry/resend, voice generation, edit/delete, assign/add-agent dialogs, and message list rendering are all in the page.
- Some helper behavior is DOM-bound, but much of the decision logic can still be tested outside Svelte.

Plan:

- Keep the page as `ChatRoom`: props, sync setup, high-level state, and composition.
- Extract `MessageList.svelte` for loading earlier messages, empty state, timestamp dividers, bubbles, thinking/sending placeholders.
- Extract `TokenWarningBanner.svelte`.
- Extract `ChatDialogs.svelte` or keep the dialogs in the page if that reads clearer; the key is to pull out repeated dialog wiring.
- Move pagination merge/state helpers to `chat-pagination-state.js`.
- Move scroll decision helpers to `chat-scroll-state.js`, leaving actual DOM scrolling in the component.
- Consider moving `messageVoicePath` once route generation includes it.

Priority: P0, after agent edit.

#### `app/frontend/pages/agents/index.svelte`

Problem:

- The page mixes list rendering, create modal, upgrade modal, icon registry, model helpers, tool checklist, color/icon pickers, and agent actions.
- Duplicates `findModelLabel`, `toggleTool`, and model select markup from edit.
- The icon import/registry is repeated in multiple files.

Plan:

- Extract `AgentCard.svelte`.
- Extract `CreateAgentDialog.svelte`.
- Extract `AgentUpgradeDialog.svelte`.
- Move icon lookup to `agent-icons.js`.
- Reuse `AgentModelSelect`, `AgentToolChecklist`, and `AgentAppearanceFields`.
- Keep page ownership of sync, create/delete/upgrade actions, and showing modals.

Priority: P0.

#### `app/frontend/pages/admin/audit-logs.svelte`

Problem:

- Filter query state, date picker setup, URL serialization, table display, pagination, selected drawer, and detail cards are all together.
- The multi-select trigger rendering is repeated four times with only source data changed.
- Debug logging remains in the component.

Plan:

- Extract pure filter parsing/serialization to `admin-audit-log-filters.js`.
- Extract `AuditLogFilters.svelte` with a small `MultiSelectFilter.svelte`.
- Extract `AuditLogTable.svelte`.
- Extract `AuditLogDrawer.svelte` and detail sections.
- Keep page responsible for props, sync subscriptions, URL navigation, and selected drawer open/close.
- Remove debug logging or gate it consistently.

Priority: P0.

#### `app/frontend/pages/chats/new.svelte`

Problem:

- Duplicates agent icon registry and model grouping/selection logic.
- Combines chat creation state, model/agent selector, group-chat agent chips, file upload, textarea autosize, and sidebar shell.
- Overlaps with `MessageComposer` but is not the same because it creates the chat.

Plan:

- Extract `ChatTargetSelect.svelte` for the combined agent/model picker.
- Extract `GroupChatAgentPicker.svelte`.
- Move model grouping to `agent-models.js` or `chat-targets.js`.
- Reuse `agent-icons.js`.
- Consider a shared `ChatTextarea.svelte` used by both `new.svelte` and `MessageComposer`.
- Keep page responsible for building `FormData` and posting `accountChatsPath`.

Priority: P0.

#### `app/frontend/pages/chats/ChatList.svelte`

Problem:

- This lives under `pages` but behaves like a shared chat component.
- Duplicates agent icon registry.
- Owns URL query toggles for deleted/agent-only filters.
- Renders chat row, group participant avatars, status markers, model/date/token/message counts in one component.

Plan:

- Move to `app/frontend/lib/components/chat/ChatList.svelte` once imports are updated.
- Extract `ChatListRow.svelte`.
- Extract `ChatListFilters.svelte`.
- Reuse `ParticipantAvatars` or introduce a smaller `ParticipantStack` for chat list rows.
- Move URL query toggle helpers to a small helper if tested value is worthwhile.

Priority: P1, but move early if touching chat pages.

#### `app/frontend/pages/chats/search.svelte`

Problem:

- Small enough, but contains custom HTML escaping/highlighting and search/pagination navigation.
- Highlighting logic is testable and security-sensitive.

Plan:

- Move `escapeHtml` and `highlightMatch` to `chat-search-highlighting.js` with tests.
- Consider extracting `ChatSearchResults.svelte` only if the page grows.

Priority: P2.

#### `app/frontend/pages/chats/index.svelte`

Problem:

- Small page, but likely overlaps with `chats/new.svelte` model selection and create-chat behavior.

Plan:

- After extracting model select helpers, update this page to reuse them.
- Otherwise leave it as a simple page.

Priority: P2.

#### `app/frontend/pages/home.svelte`

Problem:

- Content arrays plus feature card rendering live in the page.
- It is reasonably readable, but adding features means editing a long list in the Svelte file.

Plan:

- Move feature arrays to `home-features.js`.
- Extract `FeatureGrid.svelte` and `FeatureCard.svelte`.
- Keep page layout and hero in the page.

Priority: P1.

#### `app/frontend/pages/whiteboards/index.svelte`

Problem:

- List/detail/edit/conflict-resolution behavior is all in one file.
- Whiteboard conflict save logic duplicates the same shape as `WhiteboardDrawer.svelte`.
- Uses literal routes.

Plan:

- Extract `WhiteboardList.svelte`, `WhiteboardViewer.svelte`, `WhiteboardEditor.svelte`, and `WhiteboardConflictBanner.svelte`.
- Move save/conflict helper to `whiteboard-save.js` if it can be shared with `WhiteboardDrawer`.
- Keep the page as the list/detail layout and selected whiteboard URL owner.
- Use generated routes when available.

Priority: P1.

#### `app/frontend/pages/accounts/show.svelte`

Problem:

- Account information, usage, team members, pending invitations, invite form, flash rendering, and conversion state live together.
- Flash rendering is repeated elsewhere.
- Member and pending-invitation table rows are natural components.

Plan:

- Extract `FlashMessages.svelte`.
- Extract `AccountSummaryCards.svelte`, `TeamMembersTable.svelte`, `PendingInvitationsTable.svelte`, and `AccountTypeCard.svelte`.
- Keep page responsible for account props, invite/remove/resend actions, and conversion navigation.

Priority: P1.

#### `app/frontend/pages/accounts/edit.svelte`

Problem:

- Small wrapper around `Form.svelte`, but uses `$page.props` rather than explicit `$props`, unlike most pages.

Plan:

- Leave mostly alone.
- Consider explicit props for consistency if touching account form flow.

Priority: P2.

#### `app/frontend/pages/accounts/convert_confirmation.svelte`

Problem:

- Medium-sized confirmation page, likely contains several repeated account conversion detail blocks.

Plan:

- Extract only if markup has repeated warning/summary blocks.
- Otherwise leave as a page; confirmation pages are allowed to be explicit.

Priority: P1/P2 depending on future account work.

#### `app/frontend/pages/admin/accounts.svelte`

Problem:

- Split list/detail admin view with search, sync, selected account routing, details cards, and users table.
- Similar layout to audit logs and potentially other admin screens.

Plan:

- Extract `AccountList.svelte` and `AccountDetails.svelte`.
- Move search predicate to `admin-account-search.js` if reused/tested.
- Consider a shared split-view shell after both audit logs and accounts have been cleaned up.

Priority: P1.

#### `app/frontend/pages/admin/settings.svelte`

Problem:

- Moderate length settings form. Likely fine unless it repeats card/field patterns from integrations.

Plan:

- Leave until settings grow.
- If touched, extract a provider-neutral settings section component only after a second settings page needs it.

Priority: P2.

#### `app/frontend/pages/admin/jobs.svelte`

Problem:

- Small admin page. No urgent refactor.

Plan:

- Leave unless adding more job controls.

Priority: P2.

#### `app/frontend/pages/api_keys/index.svelte`

Problem:

- Page contains create form, key list, delete action, and API documentation block.
- The API documentation block is content-heavy and may grow separately from key management.

Plan:

- Extract `ApiKeyCreateForm.svelte`, `ApiKeyList.svelte`, and `ApiUsageInstructions.svelte` if the page grows.
- For now, the best immediate cleanup is moving the API endpoint list to data.

Priority: P2.

#### `app/frontend/pages/api_keys/show.svelte`, `approve.svelte`, `approved.svelte`

Problem:

- Small flow pages. They may share approval-state layout but are not currently a major pain.

Plan:

- Leave alone unless API key approval flow is being redesigned.

Priority: P2.

#### `app/frontend/pages/settings/github_integration.svelte`

Problem:

- Repeats connection status, native OAuth POST, disconnect, enabled toggle, sync-now state, and settings card patterns used by Oura/X.
- Has GitHub-specific repo selection behavior.

Plan:

- Use shared integration status/settings components.
- Keep GitHub-specific repository actions in the page or pass them as snippets/children.

Priority: P2, but high payoff if doing settings cleanup.

#### `app/frontend/pages/settings/oura_integration.svelte`

Problem:

- Same structure as GitHub integration with different copy/routes.

Plan:

- Reuse shared integration components and helper for native OAuth form POST.

Priority: P2.

#### `app/frontend/pages/settings/x_integration.svelte`

Problem:

- Same integration shape, smaller because there is no sync action.

Plan:

- Reuse shared integration components.

Priority: P2.

#### `app/frontend/pages/settings/github_select_repo.svelte`

Problem:

- Small page. Could reuse `PageHeader` and form shell after integration cleanup.

Plan:

- Leave until GitHub integration UI is refactored.

Priority: P2.

#### Auth, User, Password, Registration Pages

Files:

- `registrations/new.svelte`
- `registrations/check_email.svelte`
- `registrations/confirm_email.svelte`
- `registrations/set_password.svelte`
- `sessions/new.svelte`
- `passwords/new.svelte`
- `passwords/edit.svelte`
- `user/edit.svelte`
- `user/edit_password.svelte`

Problem:

- Mostly thin page wrappers around existing form components.
- `confirm_email.svelte` has client-side confirmation behavior that could be reviewed separately, but not for component sprawl.

Plan:

- Leave as pages.
- Use `AuthLayout` and existing forms consistently.
- Only extract confirmation status UI if another confirmation flow appears.

Priority: P2.

#### `privacy.svelte` and `terms.svelte`

Problem:

- Content pages. Length is acceptable, and component extraction would likely hide static content without improving behavior.

Plan:

- Leave alone unless converting legal/policy content to Markdown.

Priority: P2.

### Components

#### `app/frontend/lib/components/navigation/navbar.svelte`

Problem:

- Global component contains several separate menus and behaviors.
- Theme persistence, account switching, admin nav, user menu, guest menu, mobile nav, integrations nav, and search are mixed.

Plan:

- Extract `MainNavLinks.svelte`, `MobileNavMenu.svelte`, `AdminMenu.svelte`, `AccountSwitcher.svelte`, `UserMenu.svelte`, `GuestMenu.svelte`, `ThemeMenu.svelte`, and `NavSearch.svelte`.
- Move theme persistence helper to `theme-preferences.js`.
- Keep `navbar.svelte` as the top-level composition and source of `$page.props`.

Priority: P0.

#### `app/frontend/lib/components/chat/ChatHeader.svelte`

Problem:

- Broad component with local editing state, route mutations, dropdown menu, token display, admin actions, moderation request, archive/delete, fork, web access, and dialog triggers.

Plan:

- Extract `ChatTitleEditor.svelte`.
- Extract `ChatTokenStatus.svelte` and share token warning calculation with the page.
- Extract `ChatActionsMenu.svelte`.
- Consider moving mutations to callbacks provided by the page so this component becomes more render-focused.

Priority: P0.

#### `app/frontend/lib/components/chat/MessageBubble.svelte`

Problem:

- Handles user and assistant rendering in one file, including markdown, files, moderation, audio, retries, voice, thinking, tool use, and action buttons.
- Some duplication exists between user and assistant metadata rows.

Plan:

- Extract `MessageActions.svelte`, `MessageMeta.svelte`, `MessageContent.svelte`, and maybe `VoiceControls.svelte`.
- Do not split user/assistant bubbles until shared subcomponents are extracted; otherwise duplication may get worse.
- Keep the public API stable for `chats/show.svelte`.

Priority: P1.

#### `app/frontend/lib/components/chat/MessageComposer.svelte`

Problem:

- Reasonable size, but it owns form setup, fetch submission, file uploads, transcription callbacks, textarea autosize, and error handling.
- Overlaps with `chats/new.svelte`.

Plan:

- Extract shared `ChatTextarea.svelte`.
- Extract send-message request construction to a helper if it can be tested without Inertia.
- Keep as a component; no page-level concern here.

Priority: P1.

#### `app/frontend/lib/components/chat/WhiteboardDrawer.svelte`

Problem:

- Duplicates whiteboard edit/save/conflict behavior from `whiteboards/index.svelte`.

Plan:

- Share `WhiteboardEditor` and `WhiteboardConflictBanner`.
- Consider a `saveWhiteboard` helper returning `{ ok, conflict, error }`.

Priority: P1.

#### `app/frontend/lib/components/chat/AgentTriggerBar.svelte`

Problem:

- Agent grouping/rendering/action bar is moderately complex.
- Likely duplicates agent icon/colour rendering.

Plan:

- Reuse `agent-icons.js` and maybe `AgentChip.svelte`.
- Leave overall component shape intact.

Priority: P1.

#### `app/frontend/lib/components/chat/ParticipantAvatars.svelte`

Problem:

- Has icon registry and participant display logic that overlaps with `ChatList`.

Plan:

- Reuse `agent-icons.js`.
- Consider splitting a small `ParticipantAvatar.svelte` if reused in chat list rows.

Priority: P1.

#### `app/frontend/lib/components/chat/MicButton.svelte`

Problem:

- Browser media recording/transcription logic is hard to unit test as-is.

Plan:

- Leave UI component intact unless changing speech-to-text.
- If touched, move MIME selection and transcription request payload building to helpers.

Priority: P2.

#### `app/frontend/lib/components/chat/AudioPlayer.svelte`

Problem:

- Self-contained custom player. Fine.

Plan:

- Leave unless adding accessibility/keyboard controls.

Priority: P2.

#### `app/frontend/lib/components/chat/FileUploadInput.svelte`

Problem:

- Already uses file-upload helper tests elsewhere. Component is acceptable.

Plan:

- Leave unless adding drag/drop validation UI.

Priority: P2.

#### `app/frontend/lib/components/chat/FileAttachment.svelte`

Problem:

- Small component with file icon and size formatting.

Plan:

- Move `formatFileSize` to an existing utility only if reused elsewhere.

Priority: P2.

#### Small Chat Components

Files:

- `AgentPickerDialog.svelte`
- `DebugPanel.svelte`
- `EditMessageDrawer.svelte`
- `ImageLightbox.svelte`
- `TelegramBanner.svelte`
- `ThinkingBlock.svelte`
- `ToastNotification.svelte`
- `ModerationIndicator.svelte`

Plan:

- Leave mostly alone.
- `EditMessageDrawer` can share route helpers if message routes are generated.
- `ModerationIndicator` formatting can move to a helper if moderation categories appear elsewhere.

Priority: P2.

#### Form Components

Files:

- `Form.svelte`
- `LoginForm.svelte`
- `SignupForm.svelte`
- `SetPasswordForm.svelte`
- `ResetPasswordForm.svelte`
- `EditPasswordForm.svelte`
- `ChangePasswordForm.svelte`
- `UserSettingsForm.svelte`
- `InviteMemberForm.svelte`
- `ResendConfirmation.svelte`

Problem:

- Generally already componentized.
- Some may duplicate label/input/error markup, but they are not the source of current page sprawl.

Plan:

- Leave during the first pass.
- Revisit after page refactors reveal a real repeated field pattern.

Priority: P2.

#### General Components

Files:

- `Alert.svelte`
- `Avatar.svelte`
- `AvatarUpload.svelte`
- `ColourPicker.svelte`
- `IconPicker.svelte`
- `InfoCard.svelte`
- `PaginationNav.svelte`
- logo components

Plan:

- `AvatarUpload.svelte`: extract upload/delete request helpers if adding tests.
- `ColourPicker.svelte` and `IconPicker.svelte`: keep; reuse more broadly in agent components.
- `InfoCard.svelte` and `PaginationNav.svelte`: keep; they are already useful app primitives.
- `Alert.svelte`: consider replacing bespoke flash rendering with `FlashMessages.svelte`.
- Logos/layouts: leave alone.

Priority: P2.

## Suggested Execution Plan

### Phase 1: Shared Agent Foundations

1. Add `agent-icons.js`, `agent-models.js`, and `agent-memory.js` with Vitest tests.
2. Refactor `agents/edit.svelte` memory tab into components.
3. Refactor remaining `agents/edit.svelte` tabs.
4. Refactor `agents/index.svelte` to reuse the same model/tool/appearance components.
5. Update `chats/new.svelte`, `ChatList`, and `ParticipantAvatars` to use `agent-icons.js`.

Reason: this pays down the worst page first and removes duplication that affects chat screens too.

### Phase 2: Chat Room Shell

1. Extract token warning helper and banner.
2. Extract message list and placeholders from `chats/show.svelte`.
3. Extract pagination/scroll helper tests.
4. Split `ChatHeader` into title, token status, and actions menu.
5. Move `ChatList` out of `pages` and split rows/filters.

Reason: chat is central and already has good helper tests; continue that direction carefully.

### Phase 3: Admin and Whiteboards

1. Refactor audit log filters with tested URL serialization.
2. Extract audit table and drawer.
3. Extract admin account split-view pieces.
4. Share whiteboard editor/conflict UI between page and drawer.

Reason: these are self-contained areas with clear component boundaries.

### Phase 4: Content and Settings

1. Split `documentation.svelte` into data/examples/section components.
2. Move `home.svelte` feature data out of the component.
3. Create integration status/settings components and update GitHub/Oura/X pages.
4. Add small app primitives such as `PageHeader`, `EmptyState`, and `FlashMessages` only where the previous phases prove they are useful.

## Definition of Done

For each refactoring slice:

- The Inertia page remains easy to read as a page.
- Existing tests still pass.
- New pure helper modules have Vitest coverage.
- Extracted components have narrow props and no hidden `$page` dependency unless they are explicitly navigation/global components.
- Route mutations remain obvious from the page or from clearly named action components.
- No broad visual redesign is mixed into the refactor.

## Progress Checkpoint: 2026-05-03

Status: Phase 1 is partially implemented and green. This is a good commit checkpoint before continuing with the remaining `agents/edit.svelte` tabs.

Completed:

- Added shared agent helper modules with Vitest coverage:
  - `app/frontend/lib/agent-icons.js`
  - `app/frontend/lib/agent-models.js`
  - `app/frontend/lib/agent-memory.js`
- Extracted shared agent UI components:
  - `AgentModelSelect.svelte`
  - `AgentToolChecklist.svelte`
  - `AgentAppearanceFields.svelte`
  - `AgentCard.svelte`
  - `CreateAgentDialog.svelte`
  - `AgentUpgradeDialog.svelte`
  - `AgentSettingsTabs.svelte`
  - `AgentMemoryPanel.svelte`
- Refactored `agents/index.svelte` to keep page orchestration while moving card and dialog UI into components.
- Refactored `agents/edit.svelte` to move tab navigation and the memory panel into components.
- Updated `chats/new.svelte`, `ChatList.svelte`, `AgentTriggerBar.svelte`, and `ParticipantAvatars.svelte` to reuse shared agent model/icon helpers.
- Added a small Playwright assertion to the existing agent settings smoke test so the extracted Memory tab is rendered during E2E coverage.

Current size notes:

- `app/frontend/pages/agents/index.svelte`: 182 lines after extraction.
- `app/frontend/pages/agents/edit.svelte`: 555 lines after extraction, down from 878 lines before the memory/tab split.
- `AgentMemoryPanel.svelte` is intentionally still a substantial component at about 300 lines; it is a clearer boundary than keeping the whole memory workflow inside the page, but it remains a candidate for a later split into memory filters, new memory form, and memory list/card components.

Last verified test baseline:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 5 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Known notes:

- Rails tests can dirty VCR cassettes during this work; restore generated cassette churn before committing unless a cassette was intentionally changed.
- The Vite build still reports pre-existing warnings in areas such as `chats/index.svelte`, `InfoCard.svelte`, `ChatHeader.svelte`, `ColourPicker.svelte`, `IconPicker.svelte`, `FileAttachment.svelte`, and `AudioPlayer.svelte`.
- The next sensible Phase 1 slice is to continue reducing `agents/edit.svelte`, probably by extracting the Identity, Model, and Integrations panels one at a time with tests between each extraction.

## Progress Checkpoint: 2026-05-03 Continued

Status: The remaining large `agents/edit.svelte` tabs have been extracted and the test suite remains green.

Completed after commit `3381029 Refactor agent Svelte components`:

- Extracted `AgentIdentityPanel.svelte` from `agents/edit.svelte`.
- Extracted `AgentModelPanel.svelte` from `agents/edit.svelte`.
- Extracted `AgentIntegrationsPanel.svelte` from `agents/edit.svelte`.
- Kept `agents/edit.svelte` responsible for Inertia props, form initialization, route mutations, tab selection, and submit/cancel actions.

Current size notes:

- `app/frontend/pages/agents/edit.svelte`: 244 lines after the Identity, Model, and Integrations panel extractions.
- `AgentIdentityPanel.svelte`: 171 lines.
- `AgentModelPanel.svelte`: 69 lines.
- `AgentIntegrationsPanel.svelte`: 101 lines.

Last verified test baseline:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 5 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Known notes:

- The VCR cassette append cleanup from commit `25acae3 Prevent VCR cassette appends` held during this pass; the full Rails suite did not leave cassette churn in the worktree.
- `AgentMemoryPanel.svelte` is still the largest extracted agent component and remains the next obvious candidate for a smaller split if the agent area needs more refinement.
- The `appearance` tab is already thin and currently delegates to `AgentAppearanceFields.svelte`; it does not need a separate panel unless future behavior is added.

## Progress Checkpoint: 2026-05-03 Memory Panel Split

Status: The `AgentMemoryPanel.svelte` split is implemented and green.

Completed after commit `3b6553c Extract agent edit panels`:

- Extracted `AgentMemoryCard.svelte` from `AgentMemoryPanel.svelte`.
- Extracted `AgentNewMemoryForm.svelte`.
- Extracted `AgentMemoryFilters.svelte`.
- Extracted `AgentMemorySummary.svelte`.
- Kept `AgentMemoryPanel.svelte` responsible for refinement actions, filter state, the filtered-memory derivation, and list orchestration.
- Extended the agent settings Playwright smoke test to open the memory form and assert the empty form cannot be submitted.

Current size notes:

- `AgentMemoryPanel.svelte`: 124 lines, down from about 300 lines when first extracted from `agents/edit.svelte`.
- `AgentMemoryCard.svelte`: 89 lines.
- `AgentNewMemoryForm.svelte`: 64 lines.
- `AgentMemoryFilters.svelte`: 41 lines.
- `AgentMemorySummary.svelte`: 28 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 5 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Move to the next P0 target in this plan: `documentation.svelte`, which is mostly structural/content extraction rather than interactive behavior.

## Progress Checkpoint: 2026-05-03 Documentation Examples

Status: The first `documentation.svelte` extraction is implemented and green.

Completed:

- Moved large inline code example strings from `documentation.svelte` to `app/frontend/lib/documentation-examples.js`.
- Added `DocumentationCodeBlock.svelte` so the page no longer imports `svelte-highlight` languages directly.
- Added a small Playwright smoke assertion for `/documentation` so this public page renders and shows a highlighted code example.

Current size notes:

- `app/frontend/pages/documentation.svelte`: 735 lines, down from 1030 lines.
- `app/frontend/lib/documentation-examples.js`: 310 lines.
- `DocumentationCodeBlock.svelte`: 12 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Extract documentation section shells such as quick navigation and the three large topic cards, while keeping the documentation page responsible for ordering the sections.

## Progress Checkpoint: 2026-05-03 Documentation Structure

Status: The documentation shell extraction is implemented and green.

Completed after commit `bc42500 Extract documentation examples`:

- Extracted `DocumentationQuickNavigation.svelte`.
- Extracted `DocumentationTopicCard.svelte` for the repeated section card/header/content shell.
- Kept `documentation.svelte` responsible for the page title, section order, and the substantive section content.

Current size notes:

- `app/frontend/pages/documentation.svelte`: 682 lines, down from 735 lines after the examples extraction and 1030 lines originally.
- `DocumentationQuickNavigation.svelte`: 43 lines.
- `DocumentationTopicCard.svelte`: 15 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Extract each large documentation topic body one at a time, starting with the real-time synchronization section.

## Progress Checkpoint: 2026-05-03 Documentation Realtime Section

Status: The first large documentation topic body extraction is implemented and green.

Completed after commit `54eace7 Extract documentation structure`:

- Extracted `RealtimeSyncDocumentation.svelte`.
- Moved realtime-specific imports (`Badge` and sync example constants) out of `documentation.svelte`.
- Kept `documentation.svelte` as the page-level ordering layer for the documentation topics.

Current size notes:

- `app/frontend/pages/documentation.svelte`: 446 lines, down from 682 lines after the structure extraction and 1030 lines originally.
- `RealtimeSyncDocumentation.svelte`: 243 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Extract `JsonAttributesDocumentation.svelte`, then `PromptSystemDocumentation.svelte`, leaving `documentation.svelte` as a short page that composes the documentation topics.

## Progress Checkpoint: 2026-05-03 Documentation JSON Section

Status: The JSON attributes documentation topic extraction is implemented and green.

Completed after commit `313dd7b Extract realtime documentation section`:

- Extracted `JsonAttributesDocumentation.svelte`.
- Moved JSON attributes-specific example imports out of `documentation.svelte`.
- Kept `documentation.svelte` as the page-level ordering layer for the documentation topics.

Current size notes:

- `app/frontend/pages/documentation.svelte`: 262 lines, down from 446 lines after the realtime section extraction and 1030 lines originally.
- `JsonAttributesDocumentation.svelte`: 192 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Extract `PromptSystemDocumentation.svelte`, leaving `documentation.svelte` as a short page that composes the documentation topics.

## Progress Checkpoint: 2026-05-03 Documentation Prompt Section

Status: The prompt system documentation topic extraction is implemented and green.

Completed after commit `ccb03aa Extract JSON documentation section`:

- Extracted `PromptSystemDocumentation.svelte`.
- Moved prompt-specific example imports out of `documentation.svelte`.
- Reduced `documentation.svelte` to the page title and topic component ordering.

Current size notes:

- `app/frontend/pages/documentation.svelte`: 19 lines, down from 262 lines after the JSON section extraction and 1030 lines originally.
- `PromptSystemDocumentation.svelte`: 244 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Return to the P1 component list: review the largest remaining Svelte files and extract one focused component from the next most sprawling page without changing the page orchestration role.

## Progress Checkpoint: 2026-05-03 Chat Message List

Status: The first `chats/show.svelte` extraction is implemented and green.

Completed after commit `971755c Extract prompt documentation section`:

- Extracted `ChatMessageList.svelte` from `pages/chats/show.svelte`.
- Kept pagination state, scrolling decisions, sync, retry/delete/edit actions, and route ownership in the chat page.
- Changed the parent `messagesContainer` binding to `$state()` so the extraction does not introduce a new Svelte compiler warning.

Current size notes:

- `app/frontend/pages/chats/show.svelte`: 784 lines, down from 870 lines.
- `ChatMessageList.svelte`: 146 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 10 files, 29 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue inside `chats/show.svelte` with a similarly narrow extraction, likely `TokenWarningBanner.svelte` plus a small chat status/banner grouping, or move pure pagination helpers into `chat-pagination-state.js` with Vitest coverage.

## Progress Checkpoint: 2026-05-03 Chat Pagination Helpers

Status: The first pure pagination helper extraction from `chats/show.svelte` is implemented and green.

Completed after commit `5d0877d Extract chat message list`:

- Added `chat-pagination-state.js` for message deduping, load-more decisions, and prepending fetched pages.
- Added `chat-pagination-state.test.js`.
- Kept actual fetching, DOM scroll preservation, and route ownership in `pages/chats/show.svelte`.

Current size notes:

- `app/frontend/pages/chats/show.svelte`: 791 lines. This slice adds imports but moves pagination decisions into tested helpers.
- `chat-pagination-state.js`: 24 lines.
- `chat-pagination-state.test.js`: 45 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 11 files, 32 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue with either `TokenWarningBanner.svelte` and token-warning helper coverage, or move to the next P0 page: `admin/audit-logs.svelte`.

## Progress Checkpoint: 2026-05-03 Chat Token Warning

Status: Token warning logic and rendering extraction is implemented and green.

Completed after commit `eead63c Extract chat pagination helpers`:

- Added `TokenWarningBanner.svelte` for the critical conversation-length banner.
- Added `tokenWarningLevel` to `chat-utils.js`.
- Reused the helper from both `pages/chats/show.svelte` and `ChatHeader.svelte` to remove duplicated threshold logic.
- Added unit coverage for token warning thresholds.

Current size notes:

- `app/frontend/pages/chats/show.svelte`: 772 lines, down from 791 lines after the pagination helper slice and 870 lines before chat refactoring.
- `ChatHeader.svelte`: 377 lines, down from 385 lines.
- `TokenWarningBanner.svelte`: 14 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 11 files, 33 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Move to the next P0 page: `admin/audit-logs.svelte`, starting with pure audit-log filter parsing/serialization helpers and tests.

## Progress Checkpoint: 2026-05-03 Audit Log Filter Helpers

Status: The first `admin/audit-logs.svelte` extraction is implemented and green.

Completed after commit `81b1b4b Extract chat token warning`:

- Added `admin-audit-log-filters.js` for query param parsing, filter serialization, compact URL params, and selected-log removal.
- Added `admin-audit-log-filters.test.js`.
- Removed the leftover pagination debug log from `admin/audit-logs.svelte`.
- Kept router navigation, date-picker objects, sync subscriptions, and page orchestration in the page.

Current size notes:

- `app/frontend/pages/admin/audit-logs.svelte`: 462 lines, down from 478 lines.
- `admin-audit-log-filters.js`: 43 lines.
- `admin-audit-log-filters.test.js`: 61 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `admin/audit-logs.svelte` by extracting the repeated multi-select filter markup into an `AuditLogMultiSelectFilter.svelte` component, then consider table and drawer components.

## Progress Checkpoint: 2026-05-03 Audit Log Multi-Select Filters

Status: The repeated audit-log multi-select filter extraction is implemented and green.

Completed after commit `8ccfca8 Extract audit log filter helpers`:

- Added `AuditLogMultiSelectFilter.svelte`.
- Replaced the four inline user/account/action/type filter select blocks with the shared component.
- Removed filter-change debug logging from the page.
- Kept filter state, date picker state, navigation, table, and drawer orchestration in `admin/audit-logs.svelte`.

Current size notes:

- `app/frontend/pages/admin/audit-logs.svelte`: 371 lines, down from 462 lines after the filter-helper slice and 478 lines originally.
- `AuditLogMultiSelectFilter.svelte`: 33 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `admin/audit-logs.svelte` by extracting `AuditLogTable.svelte`, then `AuditLogDrawer.svelte` and detail sections.

## Progress Checkpoint: 2026-05-03 Audit Log Table

Status: The audit-log table extraction is implemented and green.

Completed after commit `f8eed5f Extract audit log filter selects`:

- Added `AuditLogTable.svelte`.
- Moved table rendering, empty state, row formatting, row selection callback, and pagination rendering out of `admin/audit-logs.svelte`.
- Kept filter state, date pickers, URL navigation, sync subscriptions, and detail drawer ownership in the page.

Current size notes:

- `app/frontend/pages/admin/audit-logs.svelte`: 318 lines, down from 371 lines after the multi-select extraction and 478 lines originally.
- `AuditLogTable.svelte`: 62 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Extract `AuditLogDrawer.svelte`, then smaller drawer detail sections if that component is still too long.

## Progress Checkpoint: 2026-05-03 Audit Log Drawer

Status: The audit-log drawer extraction is implemented and green.

Completed after commit `25cc3d4 Extract audit log table`:

- Added `AuditLogDrawer.svelte`.
- Moved detail drawer rendering, JSON highlighting, actor/object/additional/technical detail cards, and close button rendering out of `admin/audit-logs.svelte`.
- Kept selected-log URL ownership, drawer-open state, filter state, sync subscriptions, and table selection in the page.

Current size notes:

- `app/frontend/pages/admin/audit-logs.svelte`: 171 lines, down from 318 lines after the table extraction and 478 lines originally.
- `AuditLogDrawer.svelte`: 159 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- If staying in audit logs, split `AuditLogDrawer.svelte` into smaller drawer detail sections; otherwise move to the next P0 target, `chats/new.svelte` or `navbar.svelte`.

## Progress Checkpoint: 2026-05-03 New Chat Target Picker

Status: The first `chats/new.svelte` extraction is implemented and green.

Completed after commit `5e32804 Extract audit log drawer`:

- Added `ChatTargetSelect.svelte` for the combined model/agent selector.
- Added `GroupChatAgentPicker.svelte` for manual multi-agent selection.
- Reused `agent-icons.js` and `agent-models.js` from the earlier agent refactors.
- Kept the page responsible for sidebar state, web access, group-chat mode, textarea/file state, `FormData` construction, and `accountChatsPath` posting.

Current size notes:

- `app/frontend/pages/chats/new.svelte`: 207 lines, down from 319 lines after earlier shared-helper work and 403 lines originally.
- `ChatTargetSelect.svelte`: 92 lines.
- `GroupChatAgentPicker.svelte`: 46 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue with `navbar.svelte` or `ChatHeader.svelte`, both of which are now larger than the remaining new-chat page.

## Progress Checkpoint: 2026-05-03 Navbar Account Menu

Status: The first navigation extraction is implemented and green.

Completed after commit `f2aec59 Extract new chat target picker`:

- Added `UserAccountMenu.svelte` for the logged-in account dropdown.
- Moved account switching, logged-in identity display, integrations, account/API/password links, per-user theme menu, and logout menu item out of `navbar.svelte`.
- Kept the navbar responsible for current page props, public/mobile nav, admin menu, guest menu, search form, and theme persistence.

Current size notes:

- `app/frontend/lib/components/navigation/navbar.svelte`: 256 lines, down from 397 lines.
- `UserAccountMenu.svelte`: 156 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `navbar.svelte` by extracting the admin menu and mobile menu, or switch to `ChatHeader.svelte` for the next P0 component.

## Progress Checkpoint: 2026-05-03 Navbar Mobile And Admin Menus

Status: The second navigation extraction is implemented and green.

Completed after commit `e0cbe76 Extract navbar account menu`:

- Added `MobileNavMenu.svelte` for the authenticated mobile hamburger menu.
- Added `SiteAdminMenu.svelte` for site-admin navigation.
- Kept `navbar.svelte` responsible for page props, brand/desktop links, guest theme/login menu, chat search, and theme persistence.

Current size notes:

- `app/frontend/lib/components/navigation/navbar.svelte`: 198 lines, down from 256 lines after the account menu extraction and 397 lines originally.
- `MobileNavMenu.svelte`: 37 lines.
- `SiteAdminMenu.svelte`: 32 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Move to `ChatHeader.svelte`, which is now the largest remaining P0 component after `chats/show.svelte`.

## Progress Checkpoint: 2026-05-03 Chat Header Token Status

Status: The first `ChatHeader.svelte` extraction is implemented and green.

Completed after commit `9d5be70 Extract navbar menus`:

- Added `ChatTokenStatus.svelte` for the model/participant token status row and warning badges.
- Kept title editing, chat actions, moderation, archive/delete, fork, web access, and dialog callbacks in `ChatHeader.svelte`.
- Reused the existing `chat-utils.js` formatting and token-warning helper coverage.

Current size notes:

- `app/frontend/lib/components/chat/ChatHeader.svelte`: 344 lines, down from 377 lines.
- `ChatTokenStatus.svelte`: 48 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `ChatHeader.svelte` by extracting the action dropdown, then consider a focused title-edit component that can also address the current Svelte a11y warning.

## Progress Checkpoint: 2026-05-03 Chat Header Actions Menu

Status: The `ChatHeader.svelte` action dropdown extraction is implemented and green.

Completed after commit `e29e4fb Extract chat token status`:

- Added `ChatActionsMenu.svelte` for the web-access toggle, agent actions, fork, whiteboard, archive/delete, and site-admin controls.
- Kept the actual route mutations and moderation request in `ChatHeader.svelte`, passing them into the menu as callbacks.
- Preserved the existing bindable `showAllMessages` and `debugMode` state ownership.

Current size notes:

- `app/frontend/lib/components/chat/ChatHeader.svelte`: 266 lines, down from 344 lines after token status extraction and 385 lines originally.
- `ChatActionsMenu.svelte`: 112 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Extract the title-editing display/state into a focused component and address the current Svelte a11y warning around the clickable `<h1>`.

## Progress Checkpoint: 2026-05-03 Chat Header Title Editor

Status: The `ChatHeader.svelte` title editor extraction is implemented and green.

Completed after commit `c80132d Extract chat actions menu`:

- Added `ChatTitleEditor.svelte` for title display, edit mode, keyboard handling, blur save, focus/select behavior, and loading spinner.
- Kept title persistence and optimistic route mutation in `ChatHeader.svelte`.
- Replaced the clickable `<h1>` with an actual button inside the heading, removing the `ChatHeader.svelte` Svelte a11y warning from the Vite build.

Current size notes:

- `app/frontend/lib/components/chat/ChatHeader.svelte`: 186 lines, down from 266 lines after the action-menu extraction and 385 lines originally.
- `ChatTitleEditor.svelte`: 71 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed; the previous `ChatHeader.svelte` clickable-heading warning is gone.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Return to `chats/show.svelte`, the largest remaining P0 page, or move into the P1 page/component list now that `ChatHeader.svelte` and `navbar.svelte` are below 200 lines.

## Progress Checkpoint: 2026-05-03 Chat Overlays

Status: The first renewed `chats/show.svelte` extraction is implemented and green.

Completed after commit `62f27ab Extract chat title editor`:

- Added `ChatOverlays.svelte` for the whiteboard drawer, edit-message drawer, error/success toasts, assign-agent dialog, add-agent dialog, and image lightbox.
- Kept the page responsible for overlay state, selected edit/lightbox data, route callbacks, and local message updates.
- Reduced the bottom of `chats/show.svelte` to a single overlay composition block.

Current size notes:

- `app/frontend/pages/chats/show.svelte`: 745 lines, down from 772 lines after the previous chat extractions and 870 lines originally.
- `ChatOverlays.svelte`: 73 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `chats/show.svelte` by extracting scroll/pagination orchestration or moving more retry/voice/message action behavior behind focused helpers/components.

## Progress Checkpoint: 2026-05-03 Chat Input Area

Status: The chat input-area extraction is implemented and green.

Completed after commit `9132aca Extract chat overlays`:

- Added `ChatInputArea.svelte` for the group-chat agent trigger bar, archived/deleted respondability banner, and message composer.
- Kept `chats/show.svelte` responsible for message insertion, waiting state, streaming refresh scheduling, scroll-to-bottom behavior, and agent prompt timing.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/chats/show.svelte`: 723 lines, down from 745 lines after the overlay extraction and 870 lines originally.
- `ChatInputArea.svelte`: 48 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 12 files, 37 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `chats/show.svelte` by extracting pagination/scroll orchestration, or move to the P1 pages if we decide the remaining chat-room orchestration is acceptable for an Inertia page.

## Progress Checkpoint: 2026-05-03 Chat Message Collection Helpers

Status: The message collection helper extraction is implemented and green.

Completed after commit `e889e54 Extract chat input area`:

- Added `chat-message-collections.js` for patching, removing, and append-if-missing behavior across recent/older message arrays.
- Added Vitest coverage for the new helper module.
- Updated `chats/show.svelte` to use the helpers for local edit, delete, voice, and send-state updates.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/chats/show.svelte`: 724 lines.
- `chat-message-collections.js`: 20 lines.
- `chat-message-collections.test.js`: 46 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue reducing `chats/show.svelte` only where behavior can remain obvious, otherwise move on to the P1 pages: `accounts/show.svelte`, `home.svelte`, `whiteboards/index.svelte`, or `admin/accounts.svelte`.

## Progress Checkpoint: 2026-05-03 Account Team Sections

Status: The first `accounts/show.svelte` extraction is implemented and green.

Completed after commit `a1f1d3a Extract chat message collection helpers`:

- Added `TeamMembersCard.svelte` for the team member card, invite form placement, active member table, current-user badge, and remove action affordance.
- Added `PendingInvitationsCard.svelte` for the pending invitation table, invited-by rendering, resend action, and cancel action affordance.
- Kept `accounts/show.svelte` responsible for account props, realtime sync, invite/remove/resend Inertia actions, account summary cards, and account type conversion navigation.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/accounts/show.svelte`: 197 lines, down from 339 lines.
- `TeamMembersCard.svelte`: 105 lines.
- `PendingInvitationsCard.svelte`: 77 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed, including the account invitation journey.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `accounts/show.svelte` with smaller extractions such as shared flash messages and account type/summary cards, or move on to `home.svelte`, `whiteboards/index.svelte`, and `admin/accounts.svelte`.

## Progress Checkpoint: 2026-05-03 Account Page Cards

Status: The remaining high-value `accounts/show.svelte` card extractions are implemented and green.

Completed after commit `938aa3e Extract account team sections`:

- Added `FlashMessages.svelte` as a small reusable wrapper for success, notice, and alert flash rendering.
- Added `AccountSummaryCards.svelte` for account information and account usage display.
- Added `AccountTypeCard.svelte` for personal/team conversion messaging and conversion action rendering.
- Kept `accounts/show.svelte` responsible for account props, realtime sync, local invite form state, date formatting, and Inertia route actions.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/accounts/show.svelte`: 109 lines, down from 339 lines before the account refactor.
- `FlashMessages.svelte`: 17 lines.
- `AccountSummaryCards.svelte`: 50 lines.
- `AccountTypeCard.svelte`: 40 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed, including the account invitation journey.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Treat `accounts/show.svelte` as effectively done for now and move to the remaining P1 pages: `home.svelte`, `whiteboards/index.svelte`, or `admin/accounts.svelte`.

## Progress Checkpoint: 2026-05-03 Home Feature Components

Status: The planned `home.svelte` feature-data and feature-card extraction is implemented and green.

Completed after commit `340bc91 Extract account page cards`:

- Added `home-features.js` for completed and todo feature data.
- Added `FeatureGrid.svelte` and `FeatureCard.svelte` for repeated feature section/card rendering.
- Kept `home.svelte` responsible for the page title, hero, GitHub CTA, and feature section ordering.
- Replaced the home page's deprecated `<svelte:component>` feature-icon rendering with Svelte 5 dynamic component usage inside `FeatureCard.svelte`.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/home.svelte`: 44 lines, down from 299 lines.
- `home-features.js`: 190 lines.
- `FeatureCard.svelte`: 35 lines.
- `FeatureGrid.svelte`: 14 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Move to `whiteboards/index.svelte` for list/detail/editor extraction, or `admin/accounts.svelte` for admin split-view components.

## Progress Checkpoint: 2026-05-03 Whiteboard Presentation Components

Status: The first low-risk `whiteboards/index.svelte` presentation extraction is implemented and green.

Completed after commit `e3b80b2 Extract home feature cards`:

- Added `WhiteboardEmptyState.svelte` for the no-whiteboards card.
- Added `WhiteboardList.svelte` for list item rendering, selected-state styling, character count formatting, revision display, and active chat count display.
- Added `WhiteboardPlaceholder.svelte` for the empty right-hand detail pane.
- Kept `whiteboards/index.svelte` responsible for selected whiteboard URL parsing, dynamic sync, routing, edit state, save state, and conflict state.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/whiteboards/index.svelte`: 216 lines, down from 263 lines.
- `WhiteboardEmptyState.svelte`: 14 lines.
- `WhiteboardList.svelte`: 49 lines.
- `WhiteboardPlaceholder.svelte`: 13 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Continue `whiteboards/index.svelte` with viewer/editor/conflict components, but only alongside a small whiteboard journey or focused component coverage; otherwise move to `admin/accounts.svelte`.

## Progress Checkpoint: 2026-05-03 Admin Account Split View

Status: The planned `admin/accounts.svelte` split-view extraction is implemented and green.

Completed after commit `4ba59f3 Extract whiteboard presentation components`:

- Added `AdminAccountList.svelte` for the account search field, filtered list rendering, selected-state styling, inactive account styling, owner display, and empty search state.
- Added `AdminAccountDetails.svelte` for selected account header, account information/statistics cards, and users table.
- Added `AdminAccountPlaceholder.svelte` for the unselected right-hand pane.
- Kept `admin/accounts.svelte` responsible for props, search state, filtering semantics, dynamic sync, account selection routing, and date formatting.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/admin/accounts.svelte`: 68 lines, down from 238 lines.
- `AdminAccountList.svelte`: 45 lines.
- `AdminAccountDetails.svelte`: 113 lines.
- `AdminAccountPlaceholder.svelte`: 11 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Either add focused coverage before extracting whiteboard editor/save/conflict behavior, or pick the next medium page such as `accounts/convert_confirmation.svelte`, `agents/edit.svelte`, or `chats/new.svelte`.

## Progress Checkpoint: 2026-05-03 Account Conversion Cards

Status: The account conversion confirmation page extraction is implemented and green.

Completed after commit `efa9cb4 Extract admin account split view`:

- Added `ConversionBenefitList.svelte` for repeated check-mark benefit lists.
- Added `PersonalToTeamConversionCard.svelte` for personal-to-team explanation, team name input, important notes, and actions.
- Added `TeamToPersonalConversionCard.svelte` for team-to-personal explanation, eligibility warning, important notes, and actions.
- Kept `accounts/convert_confirmation.svelte` responsible for page props, team name validation, conversion PATCH requests, navigation, and conversion state.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/accounts/convert_confirmation.svelte`: 109 lines, down from 251 lines.
- `ConversionBenefitList.svelte`: 21 lines.
- `PersonalToTeamConversionCard.svelte`: 70 lines.
- `TeamToPersonalConversionCard.svelte`: 66 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Move to `chats/new.svelte` for composer/header/settings extraction, or `agents/edit.svelte` if the agent edit page has a similarly clean component boundary.

## Progress Checkpoint: 2026-05-03 New Chat Layout Components

Status: The `chats/new.svelte` layout and composer-shell extraction is implemented and green.

Completed after commit `f5c4fa2 Extract account conversion cards`:

- Added `NewChatHeader.svelte` for the mobile sidebar trigger, page title, and model/agent target picker.
- Added `NewChatSettingsBar.svelte` for web access and group-chat toggles.
- Added `NewChatEmptyState.svelte` for the centered new-conversation prompt.
- Added `NewChatComposer.svelte` for file selection, textarea binding, submit affordance, and disabled-state rules.
- Kept `chats/new.svelte` responsible for sidebar state, selected target state, group-chat selection state, textarea resizing, validation gates, FormData construction, and the Inertia chat creation POST.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/chats/new.svelte`: 148 lines, down from 207 lines.
- `NewChatHeader.svelte`: 20 lines.
- `NewChatSettingsBar.svelte`: 28 lines.
- `NewChatEmptyState.svelte`: 6 lines.
- `NewChatComposer.svelte`: 49 lines.

Last verified test baseline for this slice:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `yarn test`: 6 Playwright tests passed, including the new-chat creation journey.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.

Next sensible slice:

- Move to `agents/edit.svelte`, `agents/index.svelte`, or a small covered `chats/show.svelte` helper extraction.

## Progress Checkpoint: 2026-05-03 Agent Index Sections

Status: The `agents/index.svelte` presentation extraction is implemented and green.

Completed after commit `1864c0f Extract new chat layout components`:

- Added `AgentIndexHeader.svelte` for page title, initiation action, and create action.
- Added `AgentEmptyState.svelte` for the no-agents card.
- Added `AgentGrid.svelte` for repeated agent card layout.
- Kept `agents/index.svelte` responsible for sync, form state, create/reset/delete, initiation, upgrade modal state, model labels, and route actions.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/agents/index.svelte`: 152 lines, down from 182 lines.
- `AgentIndexHeader.svelte`: 23 lines.
- `AgentEmptyState.svelte`: 21 lines.
- `AgentGrid.svelte`: 11 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --clear --mode=test`: passed, with existing Svelte warnings unrelated to this slice.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed.

Notes from verification:

- A concurrent Rails/Playwright run caused Vite test asset races (`ENOTEMPTY` and one transient manifest parse error). Rebuilding test assets and rerunning the affected Rails test, full Rails suite, and Playwright sequentially passed.

Next sensible slice:

- `agents/edit.svelte` is already reasonably componentized; consider extracting only the page header/form shell if it buys clarity, otherwise move to `whiteboards/index.svelte` with focused coverage or a smaller settings/API page.

## Progress Checkpoint: 2026-05-03 Agent Edit Shell Components

Status: A small `agents/edit.svelte` shell extraction is implemented and green.

Completed after commit `943ce3c Extract agent index sections`:

- Added `AgentEditHeader.svelte` for the back link, edit title, and agent-specific subtitle.
- Added `AgentAppearancePanel.svelte` so the appearance tab now follows the same panel pattern as Identity, Model, Integrations, and Memory.
- Kept `agents/edit.svelte` responsible for Inertia props, sync subscriptions, form initialization, route mutations, tab selection, submit/cancel actions, and memory/Telegram side effects.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/agents/edit.svelte`: 225 lines, down from 240 lines.
- `AgentEditHeader.svelte`: 14 lines.
- `AgentAppearancePanel.svelte`: 14 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `bin/vite build --mode test`: passed, with existing Svelte warnings unrelated to this slice.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed, including the agent settings journey.

Notes from verification:

- Rails parallel workers can race while auto-building missing Vite test assets. Building with `RAILS_ENV=test bin/vite build --clear` first produced a stable `public/vite-test` manifest, after which the full Rails suite passed.

Next sensible slice:

- Treat `agents/edit.svelte` as effectively done for now and move to a remaining P1/P2 page such as `whiteboards/index.svelte`, `api_keys/index.svelte`, or the integration settings pages.

## Progress Checkpoint: 2026-05-03 API Key Page Components

Status: The `api_keys/index.svelte` presentation extraction is implemented and green.

Completed after commit `7c01e25 Extract agent edit shell`:

- Added `ApiKeyHeader.svelte` for the title and create-key action.
- Added `ApiKeyCreateForm.svelte` for the temporary key-name form.
- Added `ApiKeyList.svelte` for the empty state and repeated API key rows.
- Added `ApiUsageCard.svelte` for the API usage instructions and endpoint list.
- Kept `api_keys/index.svelte` responsible for show/hide form state, key-name state, create POST, and revoke DELETE.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/api_keys/index.svelte`: 34 lines, down from 117 lines.
- `ApiKeyCreateForm.svelte`: 18 lines.
- `ApiKeyHeader.svelte`: 17 lines.
- `ApiKeyList.svelte`: 38 lines.
- `ApiUsageCard.svelte`: 42 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed.

Next sensible slice:

- Move to the repeated integration settings pages (`github_integration.svelte`, `oura_integration.svelte`, `x_integration.svelte`) and extract shared status/settings components, or return to `whiteboards/index.svelte` with focused whiteboard coverage.

## Progress Checkpoint: 2026-05-03 Integration Settings Components

Status: The repeated integration settings page structure is extracted and green.

Completed after commit `0bae807 Extract API key page components`:

- Added `IntegrationPageHeader.svelte` for common settings page title/description layout.
- Added `IntegrationStatusCard.svelte` for the shared connection-status card shell, with provider-specific status/actions supplied as Svelte snippets.
- Added `IntegrationSettingsCard.svelte` for the repeated enabled switch, label, and explanatory copy.
- Added `integration-forms.js` to centralize native POST form submission for OAuth-style connect actions.
- Updated GitHub, Oura, and X/Twitter integration pages to use the shared components while keeping provider-specific routes, copy, sync state, repository selection, and disconnect confirmations in their pages.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/settings/github_integration.svelte`: 109 lines, down from 139 lines.
- `app/frontend/pages/settings/oura_integration.svelte`: 95 lines, down from 126 lines.
- `app/frontend/pages/settings/x_integration.svelte`: 70 lines, down from 100 lines.
- `IntegrationPageHeader.svelte`: 8 lines.
- `IntegrationStatusCard.svelte`: 23 lines.
- `IntegrationSettingsCard.svelte`: 19 lines.
- `integration-forms.js`: 14 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test test/controllers/github_integration_controller_test.rb test/controllers/oura_integration_controller_test.rb`: 27 tests, 69 assertions, 0 failures, 0 errors.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed.

Next sensible slice:

- Either add focused whiteboard coverage and continue `whiteboards/index.svelte`, or reduce another medium page/component such as `admin/settings.svelte`, `admin/audit-logs.svelte`, or `chats/ChatList.svelte`.

## Progress Checkpoint: 2026-05-03 Admin Settings Cards

Status: The `admin/settings.svelte` card extraction is implemented and green.

Completed after commit `3f0aa9d Extract integration settings components`:

- Added `SiteIdentitySettingsCard.svelte` for site name, logo preview/change/remove controls, file input, and selected-file display.
- Added `FeatureToggleSettingsCard.svelte` for the repeated global feature toggles.
- Kept `admin/settings.svelte` responsible for setting sync, form state, selected logo file state, FormData construction, submit state, logo removal, and route mutations.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/admin/settings.svelte`: 72 lines, down from 158 lines.
- `SiteIdentitySettingsCard.svelte`: 48 lines.
- `FeatureToggleSettingsCard.svelte`: 46 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test test/controllers/admin/settings_controller_test.rb`: 3 tests, 7 assertions, 0 failures, 0 errors.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed.

Next sensible slice:

- Continue with `admin/audit-logs.svelte` by extracting the filter toolbar/date filter controls, or add focused whiteboard coverage and continue `whiteboards/index.svelte`.

## Progress Checkpoint: 2026-05-03 Audit Log Filter Toolbar

Status: The `admin/audit-logs.svelte` filter toolbar extraction is implemented and green.

Completed after commit `2d7e977 Extract admin settings cards`:

- Added `AuditLogFilterToolbar.svelte` for the multi-select filters, date picker controls, date display formatting, and apply/clear buttons.
- Kept `admin/audit-logs.svelte` responsible for Inertia props, dynamic sync subscriptions, current URL/filter state, parameter normalization, selected log routing, pagination routing, and drawer state.
- Left existing route helper changes in the worktree untouched because they were pre-existing/user-generated changes.

Current size notes:

- `app/frontend/pages/admin/audit-logs.svelte`: 127 lines, down from 164 lines.
- `AuditLogFilterToolbar.svelte`: 70 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test test/controllers/admin/audit_logs_controller_test.rb`: 18 tests, 87 assertions, 0 failures, 0 errors.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed.

Next sensible slice:

- Either keep reducing audit-log admin presentation around the table/drawer components, add focused whiteboard coverage and continue `whiteboards/index.svelte`, or move to `chats/ChatList.svelte`.

## Progress Checkpoint: 2026-05-03 Chat Sidebar Components

Status: The `chats/ChatList.svelte` sidebar extraction is implemented and green.

Completed after commit `26efd5c Extract audit log filter toolbar`:

- Added `ChatSidebarHeader.svelte` for the new-chat/close controls and admin filter toggles.
- Added `ChatSidebarEmptyState.svelte` for the empty chat list.
- Added `ChatSidebarItem.svelte` for each chat link, status icon, model/date metadata, and preview text.
- Added `ChatParticipantAvatars.svelte` for grouped participant avatars.
- Added `chat-display.js` for shared initials and short-date formatting helpers.
- Kept `ChatList.svelte` responsible for sidebar open state, permissions from `$page`, URL query toggle state, navigation, and list iteration.

Current size notes:

- `app/frontend/pages/chats/ChatList.svelte`: 86 lines, down from 227 lines.
- `ChatSidebarHeader.svelte`: 57 lines.
- `ChatSidebarItem.svelte`: 56 lines.
- `ChatParticipantAvatars.svelte`: 47 lines.
- `ChatSidebarEmptyState.svelte`: 8 lines.
- `chat-display.js`: 21 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test test/controllers/chats_controller_test.rb test/integration/chat_flow_test.rb`: 47 tests, 291 assertions, 0 failures, 0 errors.

Notes:

- Stale rows from interrupted test/browser runs in the test database caused fixture foreign-key validation failures in `chat_agents`, `messages`, and `sessions`. The affected `RAILS_ENV=test` volatile rows were cleaned before rerunning the focused chat suite.

Next sensible slice:

- Finish with `whiteboards/index.svelte` by extracting the selected whiteboard viewer/editor/conflict panel while keeping sync, routing, save, and conflict orchestration in the page.

## Progress Checkpoint: 2026-05-03 Whiteboard Viewer Component

Status: The `whiteboards/index.svelte` selected-viewer extraction is implemented and green.

Completed after commit `862542b Extract chat sidebar components`:

- Added `WhiteboardViewer.svelte` for the selected whiteboard card, edit/save/cancel controls, optimistic-conflict banner, markdown rendering, and edit textarea.
- Kept `whiteboards/index.svelte` responsible for URL selection, dynamic sync subscriptions, edit/conflict/saving state, PATCH requests, revision conflict handling, and page reload orchestration.
- Left the existing `WhiteboardList`, `WhiteboardEmptyState`, and `WhiteboardPlaceholder` components intact.

Current size notes:

- `app/frontend/pages/whiteboards/index.svelte`: 146 lines, down from 216 lines.
- `WhiteboardViewer.svelte`: 96 lines.

Last verified test baseline:

- `yarn test:unit`: 13 files, 40 tests passed.
- `RAILS_ENV=test bin/vite build --clear`: passed and populated `public/vite-test` for Rails.
- `bin/rails test test/controllers/whiteboards_controller_test.rb test/controllers/api/v1/whiteboards_controller_test.rb`: 23 tests, 68 assertions, 0 failures, 0 errors.
- `bin/rails test`: 1815 tests, 7329 assertions, 0 failures, 0 errors.
- `yarn test`: 6 Playwright tests passed.

Final status:

- The chat and whiteboard refactoring items are complete. The remaining Svelte files are below the original high-risk threshold from this plan, so this is a good stopping point unless a future pass wants to polish smaller component internals or address the pre-existing Svelte build warnings.
