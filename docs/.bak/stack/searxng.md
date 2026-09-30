# SearXNG Search API (HISTORICAL — retired 2026-08-31)

> **This integration was retired with the souls.house rebrand (Step 2.4).**
> WebTool (the SearXNG-backed search tool) only served the legacy RubyLLM
> chat path; Chaos/external resident agents access the web directly and
> never used it. `app/tools/web_tool.rb` and the `searxng:` credentials are
> removed. The SearXNG instance itself (searxng.granttree.co.uk) is
> independent of this app. Kept for historical reference.

SearXNG is a free, open-source metasearch engine that aggregates results from multiple search engines. We self-host it for use as our web search backend.

**Official Documentation**: https://docs.searxng.org/
**Search API Docs**: https://docs.searxng.org/dev/search_api.html

## Our Deployment

- **Production**: `https://searxng.granttree.co.uk`
- **Development**: Point to production or run locally via Docker

## API Endpoint

```
GET /search?q=<query>&format=json
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `q` | Yes | The search query string |
| `format` | Yes | Must be `json` for API use (also: `csv`, `rss`) |
| `categories` | No | Comma-separated list: `general`, `images`, `news`, `videos`, `files`, `it`, `science`, `social media` |
| `engines` | No | Comma-separated list of specific engines to use |
| `language` | No | Language code (e.g., `en`, `de`, `fr`) |
| `pageno` | No | Page number (default: 1) |
| `time_range` | No | Filter by time: `day`, `week`, `month`, `year` |
| `safesearch` | No | 0 = off, 1 = moderate, 2 = strict |

### Example Request

```bash
curl "https://searxng.granttree.co.uk/search?q=ruby+on+rails&format=json"
```

### Response Format

```json
{
  "query": "ruby on rails",
  "number_of_results": 1000000,
  "results": [
    {
      "url": "https://rubyonrails.org/",
      "title": "Ruby on Rails — A web-app framework",
      "content": "A web-app framework that includes everything needed to create database-backed web applications...",
      "engine": "google",
      "category": "general",
      "parsed_url": ["https", "rubyonrails.org", "/", "", "", ""],
      "positions": [1]
    },
    {
      "url": "https://guides.rubyonrails.org/",
      "title": "Ruby on Rails Guides",
      "content": "Ruby on Rails Guides. These guides are designed to make you immediately productive with Rails...",
      "engine": "duckduckgo",
      "category": "general",
      "positions": [2]
    }
  ],
  "suggestions": ["rails framework", "ruby programming"],
  "infoboxes": []
}
```

### Key Response Fields

| Field | Description |
|-------|-------------|
| `results` | Array of search results |
| `results[].url` | The URL of the result |
| `results[].title` | The title/headline |
| `results[].content` | Snippet/description text |
| `results[].engine` | Which search engine provided this result |
| `suggestions` | Related search suggestions |
| `number_of_results` | Estimated total results |

## Ruby Usage

Simple HTTP request with Net::HTTP:

```ruby
require 'net/http'
require 'json'

def search(query, num_results: 10)
  uri = URI("https://searxng.granttree.co.uk/search")
  uri.query = URI.encode_www_form(q: query, format: 'json')

  response = Net::HTTP.get_response(uri)
  return [] unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  data['results'].first(num_results)
end
```

## Configuration

SearXNG requires a `settings.yml` to enable the JSON API:

```yaml
general:
  instance_name: "HelixKit Search"

search:
  formats:
    - html
    - json  # Required for API access

server:
  limiter: false  # Disable rate limiting for internal use
  secret_key: "your-secret-key-here"

engines:
  # Enable/disable specific engines
  - name: google
    disabled: false
  - name: duckduckgo
    disabled: false
  - name: bing
    disabled: false
```

## Kamal Deployment

Add as accessory in `config/deploy.yml`:

```yaml
accessories:
  searxng:
    image: searxng/searxng:latest
    host: 95.217.118.47
    port: 8080
    env:
      clear:
        SEARXNG_BASE_URL: "https://searxng.granttree.co.uk"
    files:
      - config/searxng/settings.yml:/etc/searxng/settings.yml
    directories:
      - searxng-data:/var/cache/searxng
```

## Local Development with Docker

```bash
# Create config directory
mkdir -p config/searxng

# Create settings.yml (see Configuration above)

# Run container
docker run -d --name searxng \
  -p 8888:8080 \
  -v "./config/searxng:/etc/searxng" \
  searxng/searxng:latest

# Test it
curl "http://localhost:8888/search?q=test&format=json"
```

## Error Handling

SearXNG returns standard HTTP status codes:

| Status | Meaning |
|--------|---------|
| 200 | Success |
| 400 | Bad request (missing/invalid params) |
| 429 | Rate limited (if limiter enabled) |
| 500 | Server error |

Empty results return 200 with `"results": []`.

## Rate Limiting

By default, SearXNG includes a rate limiter to prevent abuse. For internal API use, we disable it in `settings.yml` with `limiter: false`.

If you keep the limiter enabled, configure it in `limiter.toml`.
