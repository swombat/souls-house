Ok, so it's time to start implementing the payments system.

No app kit is complete without this. If you can't charge users, you don't have a business, you just have an expensive hobby!

We're going to use the pay gem to handle payments. This is documented in the /docs/stack/pay-overview.md file and associated files.

Here are the ways that we need to be able to charge users:

1) The charging will be associated with an account, not a user. This should work with both personal accounts and team accounts.
2) One of the key approaches to charging, which we need to be able to flexibly switch around, is that the likely ideal charging is going to be a mix of subscription costs and token usage costs.
3) So the system needs to support:
  - monthly charges
  - monthly/daily token limits
  - pay as you go (buy X tokens in advance) token charges
  - a free account with tight limits on usage
  - and of course not all tokens are the same... we need to keep track of token usage by model

This is a bit of a challenge! The RubyLLM model registry helps with this - https://rubyllm.com/models/ - documented in docs/ruby-llm/model-registry.md . And then of course we have the very full-featured pay gem documented in /docs/stack/pay-overview.md .

As part of this, we do need some way to track token usage by account. I suspect the way to do that is via the Chat model that is already in place. Hopefully the "tracking token usage" functionality is documented in the docs (if not, download this) - https://rubyllm.com/chat/#tracking-token-usage

In effect, we need to be able to switch the app between the following modes of charging:

- "Pay $20/m for usage" (with a token cost limit)
- "Pay $10 for X credits" (maps to a token limit, and can be set to recharge when the credits run out, or to just run out and stop responding)
- "Pay $20/m for usage and $10 extra for each X credits" (maps to a token limit, and can be set to recharge when the credits run out, or to just run out and stop responding)
- "Choose to pay either $20/m for one usage limit, or $100/m for a higher limit, or $200/m for an even higher limit"

Ideally, this can be done in the admin panel rather than requiring code changes. The admin panel should be able to set the desired margin (e.g. 50% margin would mean that the user pays $20 for $10 of input/output tokens, whether as a subscription or as a pay as you go purchase), and to specify the plan price points, and to specify whether there is some additional surcharge for a plan (e.g. a $20/m plan might include $10 of tokens at 50% margin, plus $10 for other costs), and to specify the chunks of payg additional tokens.

This means that e.g. the chat functionality controller will need to be able to import something like a concern that gates the methods so they refuse to do more AI processing if the account is out of tokens.

I want this done in an elegant, rails-like way. Don't over-engineering it, but do support the above use cases, as they are required to be able to discover a viable business model when developing a new AI app.

## Clarifications

1. **Token tracking granularity**: Use RubyLLM's documented methods for token tracking.

2. **Account limits enforcement**: Complete any requests currently in progress. Refuse new chat requests (messages or new chats) with an error that token limits have been reached. No warnings for now. Token limits are account-based, so multiple users on a team account share the same limit.

3. **Plan switching behavior**: Users continue on their existing plan. When upgrading, they only see active plans. Admin defines plans with three statuses:
   - **Active**: Can be selected for new subscriptions or upgrades
   - **Legacy**: Continue to function for existing accounts but can't be selected for new subscriptions
   - **Inactive**: Accounts on inactive plans are not allowed any token usage

4. **Initial implementation scope**: Start without admin UI (build later). Use database table with appropriate columns, not config files.

5. **Pay-as-you-go auto-recharge**: Per-account setting. User chooses:
   - Manual recharge vs auto-recharge
   - How much to add when auto-recharge triggers
   - Maximum auto-recharge limit

6. **Model-specific pricing**: All models available at all tiers but consume tokens at different rates based on their actual costs.