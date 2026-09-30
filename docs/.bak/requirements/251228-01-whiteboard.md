The agents want a way to create and manage shared working memory.

This is separate from the private memories we've built already. The goal is to have a series of "whiteboards" that they can all edit.

Here are some key requirements for those boards:

## ID, Name and Summary

Boards should have an ID, name and summary (as well as longer content), maximum 250 characters, to be part of an index. The name and summary can change. The ID should not change once created.

## Basic revision tracking

We're not doing full version control, but let's have a timestamp for the last edit, and the user or agent who made the last edit (likely with a polymorphic last_edited_by association). Also keep a revision number, which is incremented each time the board is edited.

## Index

The system prompt should include a list of all boards with their brief summaries and lengths, so all agents know the boards available.

## Active board

Each conversation can have an active board. This board is then automatically injected into the conversation context in full (after the memories). This is per-conversation, not global.

## Max length

Boards have a (soft) maximum length of 10'000 characters. If they get longer, the system prompt index notifies that this board is too long and needs to be summarised for efficiency, though the system will not itself truncate the board. But all agents will be notified and so able to use a tool to summarise the board.



## Tools

We need some tools to manage the boards:

- `create_board`: create a new board
- `update_board`: update an existing board
- `delete_board`: delete a board (soft delete, so it can be restored)
- `view_deleted_boards`: get a list of all deleted boards
- `restore_board`: restore a deleted board
- `list_boards`: list all boards
- `get_board`: get a board by ID
- `set_active_board`: set the active board for a conversation (can be set to nil)

All those tools need to be part of the spec. Maybe they can be grouped in a clever way. Please have a think about it.

## Clarifications

1. **Scope**: Boards are account-scoped (each account has its own set of boards, isolated from other accounts).

2. **Content format**: Markdown format for board content.

3. **Conversation model**: The conversation is represented by the `Chat` model, specifically those that are multi-agent (group chats with `manual_responses?` = true).

4. **Injection pattern**: Follow the existing memory injection pattern used in `Agent#memory_context` and `Chat#system_message_for`.

5. **Soft delete behavior**: When a board is soft-deleted, it should be automatically unset as the active board for any conversations that had it active.