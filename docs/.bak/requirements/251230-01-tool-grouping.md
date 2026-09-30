We want to add tools for viewing and changing the conversation consolidation and the memory management prompt. But we don't want to drown the models with too many tools. The agents themselves have suggested grouping tools into more flexible polymorphic tools. See below:

Consolidate the existing prompt-related tools into a single polymorphic tool, e.g. prompt_manager(prompt_type, action, content?), where prompt_type is an enum covering every editable “driver prompt” (at minimum: system, and later conversation_consolidation, memory_management, etc.), and action is an enum like view or update (optionally list_types if you want discoverability). This replaces the expanding set of view_X_prompt / update_X_prompt tools with one stable schema whose surface area grows only by adding new prompt_type values. On the server side, enforce validation (allowed prompt types, required content for updates), and return structured errors that include allowed_prompt_types / allowed_actions so the model can self-correct without extra tool definitions.

Similarly, merge web_search and web_fetch into one web(action, query_or_url, options?) tool, where action is search or fetch and the second argument is interpreted accordingly (string query for search, URL for fetch). Keep the tool description short, but make the result schema consistent: always return an array of “items” with a shared shape when possible (e.g., {type, title, url, snippet, content?}), and include a clear type: 'search_result' | 'fetched_page' so the model can reliably branch. This reduces tool count while preserving capability, and it makes it easier to add future web actions (e.g. extract, crawl) without adding new tools.

The important design constraint is that adding new prompts or web features should almost never require creating a new tool—only adding a new enum value or action branch—so your tool schemas stay stable and your context doesn’t bloat as Nexus grows.

Please document this approach in a document in /docs/, referred to in the overview.md file.

As part of this work, please update the prompt manager so it can also be used to view and change the conversation consolidation and the memory management prompt, not just the system prompt.

## Clarifications

1. **Prompt types for prompt_manager**: The tool should support all three prompt types on the Agent model:
   - `system` → `system_prompt` field
   - `conversation_consolidation` → `reflection_prompt` field
   - `memory_management` → `memory_reflection_prompt` field
   - Additionally, agent `name` should be changeable via this tool

2. **Context restriction**: The prompt_manager tool should only work in group chat contexts (agents only exist there currently)

3. **Web tool scope**: Just consolidate `search` and `fetch` actions for now - no need to design for future actions like `extract` or `crawl`