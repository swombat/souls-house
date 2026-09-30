One of our users has an Oura ring, and they want to use it to share their state with the Agents.

Please research the Oura API integration (probably involving OAuth) and plan how to set up the integration.

Also have a think about _what_ data Oura will provide, and how that data could be shared with agents, given the limitations of the messaging API.

## Clarifications

1. **User Scope**: This should be a general feature available to any user who wants to connect their Oura ring - full OAuth flow with UI required.

2. **Data Sharing**: Automatic context injection, ideally in the system prompt so agents are aware of the user's health state without needing to explicitly request it.

3. **Data Scope**: Flexible - could include real-time/recent data (last night's sleep, today's activity, readiness score), trends, and specific events. The implementation should be comprehensive enough to surface useful health context.