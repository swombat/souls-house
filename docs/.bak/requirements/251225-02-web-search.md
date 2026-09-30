We currently have a web fetch tool that allows the AI to fetch and read web pages given a URL.

It would also be useful to have a web search tool that allows the AI to search the web given a query.

Please research how best to implement this, and spec out how to implement it. Ideally this will only be using free/open APIs rather than needing to pay for a service.

If there is no way to do this well without sigining up for some kind of service, please pause implementation and present the best options for selection by the user.

## Clarifications

1. **Result format**: Return a list of URLs with snippet summaries so the AI can decide which results to fetch in full.

2. **Rate limiting**: Not needed - this is not a high volume app at this point.

3. **Feature gating**: A single "web access" checkbox should enable both web fetch and web search tools. The existing `can_fetch_urls` field should be renamed/repurposed to `web_access` or similar.

## Technical Decision

**Backend: Self-hosted SearXNG**

After researching options, we decided to use a self-hosted SearXNG instance rather than a paid API:

- **Production**: Deployed via Kamal accessory at `searxng.granttree.co.uk`
- **Development**: Can point to production instance or run locally via Docker
- **API**: Simple JSON endpoint at `/search?q=query&format=json`
- **Benefits**: Completely free, no quotas, full control, privacy-focused
- **Trade-offs**: Extra infrastructure to manage, but minimal overhead