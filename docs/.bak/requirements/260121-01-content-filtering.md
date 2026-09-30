RubyLLM has a quick model for moderating text content: https://rubyllm.com/moderation/

I'd like the system to be updated so every message, once posted/completed, gets evaluated by the moderation model.

This is not for the purpose of stopping that message, but for giving a visual display/score to the user. Some models (like Grok) also need to be evaluated by the moderation model - to best to evaluate every response after it's completed.

I imagine an exclamation mark/warning icon appearing next to the message if it gets any kind of score. Tapping the icon would show a pane (from the bottom of the screen) with any details the moderation system can provide.

This likely means Messages need to have a new column added to the database to store the moderation information, and there needs to be a job that runs after the message is completed or posted by the user, that calls the appropriate RubyLLM moderation model.

## Clarifications

1. **Warning intensity based on severity**: Each moderation category comes with a rating/score. Since we're not blocking content (some AI providers do that themselves), the purpose is to let users see when content is becoming risky. Show a warning flag for ANY flagged category, and use colour intensity to convey severity - more serious warnings should have more intense visual treatment.

2. **Moderate both user AND assistant messages**: Yes, both types need moderation. Grok often goes overboard, and one agent's messages can trigger content moderation issues in another agent's context.

3. **Single warning icon, detailed bottom sheet**: Display just one warning sign per message regardless of how many categories are flagged. When tapped, the bottom sheet shows all the details (all flagged categories with their scores).

4. **Always on**: No opt-out or configuration needed. Moderation indicators are on for everyone.