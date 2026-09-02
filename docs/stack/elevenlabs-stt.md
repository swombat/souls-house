# ElevenLabs Speech-to-Text API Documentation

## Version Information
- API Version: v1
- Documentation Source: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
- Fetched: 2026-02-14

## Overview

ElevenLabs Speech-to-Text API provides advanced transcription capabilities through two models:
- **Scribe v2**: Batch processing with comprehensive features (90+ languages, speaker diarization, entity detection)
- **Scribe v2 Realtime**: Low-latency WebSocket-based streaming transcription (~150ms latency)

### Key Capabilities
- Accurate transcription in 90+ languages with varying Word Error Rate (WER)
- Word-level and character-level timestamps
- Speaker diarization supporting up to 32 speakers
- Dynamic audio event tagging (e.g., laughter, footsteps)
- Entity detection (56 entity types: PII, PHI, PCI, offensive language)
- Keyterm prompting (up to 100 terms) for vocabulary bias
- Multichannel support (up to 5 channels processed independently)

---

## 1. Authentication

### API Key
Authentication uses the `xi-api-key` header parameter.

**Obtaining API Key:**
Create an API key in the [ElevenLabs dashboard](https://elevenlabs.io/app/settings/api-keys)

**Usage in Requests:**
```http
POST /v1/speech-to-text
xi-api-key: your_api_key_here
```

**Best Practice:**
Store API key as environment variable:
```bash
export ELEVENLABS_API_KEY=your_api_key_here
```

---

## 2. Batch Transcription API (REST)

### Endpoint Details

**Base URL:** `https://api.elevenlabs.io`

**Endpoint:** `POST /v1/speech-to-text`

**Content-Type:** `multipart/form-data`

**Alternative Servers:**
- Production: `https://api.elevenlabs.io/`
- Production US: `https://api.us.elevenlabs.io/`
- Production EU: `https://api.eu.residency.elevenlabs.io/`
- Production India: `https://api.in.residency.elevenlabs.io/`

### Request Parameters

#### Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `model_id` | string | Must be `scribe_v1` or `scribe_v2` (recommended) |

#### Audio Input (Mutually Exclusive - Exactly One Required)

| Parameter | Type | Limits | Description |
|-----------|------|--------|-------------|
| `file` | binary | Up to 3GB | Audio/video file uploaded directly |
| `cloud_storage_url` | string | Up to 2GB | HTTPS URL to file (AWS S3, Google Cloud Storage, Cloudflare R2, etc.) |

#### Optional Processing Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `language_code` | string | auto-detect | ISO-639-1 or ISO-639-3 code (e.g., "en", "es", "fra") |
| `tag_audio_events` | boolean | true | Tag sounds like "(laughter)", "(footsteps)" |
| `num_speakers` | integer | auto | Number of speakers (max 32) for improved diarization |
| `diarize` | boolean | false | Enable speaker identification |
| `diarization_threshold` | double | auto | Control speaker clustering sensitivity |
| `timestamps_granularity` | enum | word | Options: `none`, `word`, `character` |
| `temperature` | double | 0.0 | Randomness (0.0-2.0); higher = more creative |
| `seed` | integer | random | Deterministic results (0-2147483647) |
| `use_multi_channel` | boolean | false | Process up to 5 channels independently |
| `file_format` | enum | other | `pcm_s16le_16` (optimized) or `other` (auto-detect) |

#### Advanced Features (Additional Costs Apply)

| Parameter | Type | Limits | Description |
|-----------|------|--------|-------------|
| `keyterms` | array | max 100 items | Terms to bias transcription (<50 chars, ≤5 words each) |
| `entity_detection` | object | — | Detect PII, PHI, PCI, offensive language |
| `additional_formats` | array | — | Export as docx, html, pdf, segmented_json, srt, txt |

#### Webhook Parameters (Async Processing)

| Parameter | Type | Limits | Description |
|-----------|------|--------|-------------|
| `webhook` | boolean | false | Process asynchronously via webhooks |
| `webhook_id` | string | — | Target specific webhook |
| `webhook_metadata` | object | max 16KB, depth ≤2 | Custom JSON for request correlation |

#### Privacy & Logging

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enable_logging` | boolean | true | Set to false for zero-retention mode (Enterprise only) |

### Supported Audio/Video Formats

**Audio:** AAC, MP3, WAV, FLAC, Opus, WebM, and all major formats

**Video:** MP4, MOV, WebM, MKV, AVI, and all major containers

**Optimized Format:** 16-bit PCM, 16kHz sample rate, mono, little-endian (`file_format: pcm_s16le_16`)

### File Size and Duration Limits

| Limit Type | Value |
|------------|-------|
| Local file upload | 3GB |
| Cloud storage URL | 2GB |
| Maximum duration | 10 hours |
| Concurrency (files >8 min) | 4-way parallelization |

### Example Request (cURL)

```bash
curl -X POST https://api.elevenlabs.io/v1/speech-to-text \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "model_id=scribe_v2" \
  -F "file=@/path/to/audio.mp3" \
  -F "language_code=en" \
  -F "diarize=true" \
  -F "tag_audio_events=true" \
  -F "timestamps_granularity=word"
```

### Example Request (Ruby with HTTParty)

```ruby
require 'httparty'

response = HTTParty.post(
  'https://api.elevenlabs.io/v1/speech-to-text',
  headers: {
    'xi-api-key' => ENV['ELEVENLABS_API_KEY']
  },
  multipart: true,
  body: {
    model_id: 'scribe_v2',
    file: File.new('/path/to/audio.mp3'),
    language_code: 'en',
    diarize: true,
    tag_audio_events: true,
    timestamps_granularity: 'word'
  }
)

puts response.body
```

### Response Format

#### Single Channel Response (200 OK)

```json
{
  "language_code": "en",
  "language_probability": 0.98,
  "text": "Hello, how are you today?",
  "words": [
    {
      "text": "Hello",
      "start": 0.12,
      "end": 0.48,
      "speaker_id": 0,
      "logprob": -0.034,
      "characters": [
        {"char": "H", "start": 0.12, "end": 0.15},
        {"char": "e", "start": 0.15, "end": 0.18}
        // ... more characters
      ]
    },
    {
      "text": "how",
      "start": 0.52,
      "end": 0.72,
      "speaker_id": 1,
      "logprob": -0.021,
      "characters": [...]
    }
    // ... more words
  ],
  "entities": [
    {
      "text": "John Smith",
      "type": "pii",
      "start_char": 45,
      "end_char": 55
    }
  ],
  "transcription_id": "abc123xyz789"
}
```

#### Multichannel Response (200 OK)

```json
{
  "transcripts": [
    {
      "channel_index": 0,
      "language_code": "en",
      "language_probability": 0.97,
      "text": "Channel 1 transcript...",
      "words": [...]
    },
    {
      "channel_index": 1,
      "language_code": "en",
      "language_probability": 0.95,
      "text": "Channel 2 transcript...",
      "words": [...]
    }
  ],
  "transcription_id": "multi_abc123"
}
```

#### Webhook Response (Async Processing)

```json
{
  "message": "Request accepted",
  "request_id": "req_123",
  "transcription_id": "trans_456"
}
```

#### Error Response (422 Validation Error)

```json
{
  "error": {
    "message": "Validation failed",
    "details": [
      {
        "field": "model_id",
        "issue": "Invalid model identifier"
      }
    ]
  }
}
```

### Response Headers

Track usage and costs via response headers:

```http
x-character-count: 1234
request-id: req_abc123xyz
```

---

## 3. Realtime Transcription API (WebSocket)

### Connection Details

**Endpoint:** `wss://api.elevenlabs.io/v1/speech-to-text/realtime`

**Protocol:** WebSocket (WSS)

**Latency:** ~150ms

### Available Servers

| Region | WebSocket URL |
|--------|---------------|
| Production (Global) | `wss://api.elevenlabs.io/` |
| Production US | `wss://api.us.elevenlabs.io/` |
| Production EU | `wss://api.eu.residency.elevenlabs.io/` |
| Production India | `wss://api.in.residency.elevenlabs.io/` |

### Authentication Methods

1. **API Key Header:**
```
xi-api-key: your_api_key_here
```

2. **Token Query Parameter (Client-Side):**
```
wss://api.elevenlabs.io/v1/speech-to-text/realtime?token=single_use_token
```

**Note:** Use tokens for client-side transcription to avoid exposing API keys.

### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `model_id` | string | — | Model identifier (e.g., "scribe_v2") |
| `audio_format` | enum | pcm_16000 | Options: pcm_8000, pcm_16000, pcm_22050, pcm_24000, pcm_44100, pcm_48000, ulaw_8000 |
| `language_code` | string | auto | ISO 639-1 or ISO 639-3 format |
| `commit_strategy` | enum | manual | `manual` or `vad` (voice activity detection) |
| `include_timestamps` | boolean | false | Word-level timing data |
| `include_language_detection` | boolean | false | Language identification |
| `vad_silence_threshold_secs` | number | 1.5 | Silence duration before commit (VAD mode) |
| `vad_threshold` | number | 0.4 | Voice activity sensitivity (0.0-1.0) |
| `min_speech_duration_ms` | integer | 100 | Minimum speech segment length |
| `min_silence_duration_ms` | integer | 100 | Minimum pause duration |
| `enable_logging` | boolean | true | Zero-retention mode when false |

### Message Flow

#### Client -> Server (Input Audio Chunk)

```json
{
  "message_type": "input_audio_chunk",
  "audio_base_64": "base64_encoded_audio_data",
  "commit": false,
  "sample_rate": 16000,
  "previous_text": "Optional context for first chunk only"
}
```

**Fields:**
- `message_type`: Always "input_audio_chunk"
- `audio_base_64`: Base64-encoded PCM audio
- `commit`: true to finalize current segment (manual mode only)
- `sample_rate`: Audio sample rate in Hz (must match audio_format)
- `previous_text`: Context for first chunk; improves accuracy

#### Server -> Client Messages

**Session Started:**
```json
{
  "message_type": "session_started",
  "session_id": "session_123",
  "model_id": "scribe_v2",
  "audio_format": "pcm_16000",
  "language_code": "en"
}
```

**Partial Transcript (Interim Results):**
```json
{
  "message_type": "partial_transcript",
  "text": "Hello how are"
}
```

**Committed Transcript (Final):**
```json
{
  "message_type": "committed_transcript",
  "text": "Hello, how are you today?"
}
```

**Committed Transcript with Timestamps:**
```json
{
  "message_type": "committed_transcript_with_timestamps",
  "text": "Hello, how are you today?",
  "words": [
    {
      "text": "Hello",
      "start": 0.12,
      "end": 0.48
    },
    {
      "text": "how",
      "start": 0.52,
      "end": 0.72
    }
  ]
}
```

**Error Messages:**
```json
{
  "message_type": "auth_error",
  "error": "Invalid API key"
}
```

**Error Types:**
- `auth_error`: Authentication failed
- `quota_exceeded`: Usage quota exceeded
- `rate_limited`: Too many requests
- `resource_exhausted`: System resources unavailable
- `session_time_limit_exceeded`: Session duration exceeded

### Example WebSocket Client (JavaScript)

```javascript
const ws = new WebSocket('wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2&audio_format=pcm_16000', {
  headers: {
    'xi-api-key': process.env.ELEVENLABS_API_KEY
  }
});

ws.on('open', () => {
  console.log('WebSocket connected');

  // Send audio chunk
  const audioChunk = {
    message_type: 'input_audio_chunk',
    audio_base_64: audioBase64,
    commit: false,
    sample_rate: 16000
  };

  ws.send(JSON.stringify(audioChunk));
});

ws.on('message', (data) => {
  const message = JSON.parse(data);

  switch(message.message_type) {
    case 'session_started':
      console.log('Session started:', message.session_id);
      break;
    case 'partial_transcript':
      console.log('Partial:', message.text);
      break;
    case 'committed_transcript':
      console.log('Final:', message.text);
      break;
    case 'auth_error':
    case 'quota_exceeded':
    case 'rate_limited':
      console.error('Error:', message);
      break;
  }
});
```

---

## 4. Language Support and Accuracy

### Language Tiers (by Word Error Rate)

**Excellent (≤5% WER):**
English, Spanish, French, German, Japanese, Italian, Portuguese, Dutch, Polish, Turkish, Korean, Swedish, Danish, Norwegian, Finnish, Czech, Romanian, Greek, Hungarian, Indonesian, Malay, Slovak, Ukrainian, Bulgarian, Croatian, Lithuanian, Latvian, Estonian, Slovenian, Icelandic, Catalan, Serbian

**High Accuracy (5-10% WER):**
Hindi, Arabic, Mandarin, Bengali, Tamil, Telugu, Gujarati, Kannada, Malayalam, Punjabi, Urdu, Vietnamese, Thai, Russian, Persian, Hebrew, Swahili, Zulu

**Good Performance (10-20% WER):**
Thai, Korean, Hebrew, Afrikaans, Albanian, Azerbaijani, Belarusian, Bosnian, Galician, Georgian, Irish, Kazakh, Macedonian, Maltese, Mongolian, Welsh

**Moderate Accuracy (25-50% WER):**
Amharic, Lao, Somali, Nepali, Sinhala, Khmer, Burmese, and others

**Total Languages:** 90+

---

## 5. Pricing and Rate Limits

### Pricing Model

**Billing:** Per hour of audio transcribed

**Starting Price:** $0.40/hour (scales down with volume)

**Additional Costs:**
- **Keyterm prompting:** Additional per-hour fee
- **Entity detection:** Additional per-hour fee

**Enterprise Plans:** Custom pricing with volume discounts

### Rate Limits

**Standard Plans:** Standard rate limits (specific values not publicly documented)

**Enterprise Plans:** Custom rate limits, dedicated support, SLAs

**Quota Management:** Track usage via response headers and dashboard

---

## 6. SDK and Client Libraries

### Official SDKs

**TypeScript/JavaScript:**
```bash
bun add @elevenlabs/elevenlabs-js
```

**Python:**
```bash
pip install elevenlabs
```

### Community Ruby SDKs

**elevenlabs_client** (Recommended - Full feature support):
```ruby
# Gemfile
gem 'elevenlabs_client'
```

Supports: Voice synthesis, dubbing, speech transcription, audio isolation, and more.

**elevenlabs-ruby:**
```ruby
# Gemfile
gem 'elevenlabs-ruby'
```

Primary focus on text-to-speech, limited STT support.

**elevenlabs-rb:**
```ruby
# Gemfile
gem 'elevenlabs-rb'
```

Unofficial lightweight wrapper.

### Example Usage (Python SDK)

```python
from elevenlabs import ElevenLabs
from dotenv import load_dotenv
import os

load_dotenv()
client = ElevenLabs(api_key=os.getenv('ELEVENLABS_API_KEY'))

# Transcribe from file
with open('audio.mp3', 'rb') as audio_file:
    result = client.speech_to_text.convert(
        model_id='scribe_v2',
        file=audio_file,
        language_code='en',
        diarize=True,
        tag_audio_events=True
    )

print(result.text)
```

### Example Usage (JavaScript SDK)

```javascript
import { ElevenLabsClient } from '@elevenlabs/elevenlabs-js';
import * as fs from 'fs';

const client = new ElevenLabsClient({
  apiKey: process.env.ELEVENLABS_API_KEY
});

const audioFile = fs.readFileSync('audio.mp3');

const result = await client.speechToText.convert({
  modelId: 'scribe_v2',
  file: audioFile,
  languageCode: 'en',
  diarize: true,
  tagAudioEvents: true
});

console.log(result.text);
```

---

## 7. Best Practices and Implementation Tips

### Audio Quality
- Use 16kHz+ sample rate for best accuracy
- Mono audio preferred (or use multichannel for multiple speakers)
- Minimize background noise
- Use `file_format: pcm_s16le_16` for optimized processing

### Speaker Diarization
- Set `num_speakers` if known for better accuracy
- Adjust `diarization_threshold` for overlapping speakers
- Use multichannel mode if speakers recorded on separate channels

### Language Detection
- Omit `language_code` for auto-detection
- Provide `language_code` if known for faster processing
- Check `language_probability` in response to validate detection

### Keyterm Prompting
- Use for technical vocabulary, proper nouns, or domain-specific terms
- Limit to 100 terms maximum
- Each term must be <50 characters, ≤5 words
- Note: Incurs additional costs

### Entity Detection
- Enable for PII/PHI compliance needs
- Supported types: `pii`, `phi`, `pci`, `offensive_language`, `other`
- Returns entity positions for redaction
- Note: Incurs additional costs

### Async Processing (Webhooks)
- Use for large files (>10 minutes)
- Configure webhook endpoint in dashboard
- Include `webhook_metadata` for request correlation
- Poll or wait for webhook callback

### Privacy and Compliance
- Set `enable_logging: false` for zero-retention (Enterprise only)
- Use HIPAA-compliant deployments via ElevenLabs Sales (BAA required)
- Process sensitive data on EU/India residency servers

### Performance Optimization
- Files >8 minutes automatically parallelized (4-way)
- Use cloud_storage_url for large files to avoid upload time
- Consider realtime WebSocket API for live transcription (<150ms latency)

---

## 8. Error Handling

### HTTP Status Codes

| Code | Meaning | Action |
|------|---------|--------|
| 200 | Success | Process transcription result |
| 401 | Unauthorized | Check API key validity |
| 422 | Validation Error | Review request parameters |
| 429 | Rate Limited | Implement exponential backoff |
| 500 | Server Error | Retry with exponential backoff |

### Common Errors

**Invalid model_id:**
```json
{
  "error": {
    "message": "Invalid model identifier",
    "field": "model_id"
  }
}
```

**File too large:**
```json
{
  "error": {
    "message": "File size exceeds limit (3GB for upload, 2GB for URL)"
  }
}
```

**Quota exceeded:**
```json
{
  "error": {
    "message": "Usage quota exceeded for current billing period"
  }
}
```

### Retry Strategy

```ruby
def transcribe_with_retry(file_path, max_retries: 3)
  retries = 0

  begin
    response = HTTParty.post(
      'https://api.elevenlabs.io/v1/speech-to-text',
      headers: { 'xi-api-key' => ENV['ELEVENLABS_API_KEY'] },
      multipart: true,
      body: {
        model_id: 'scribe_v2',
        file: File.new(file_path)
      }
    )

    case response.code
    when 200
      JSON.parse(response.body)
    when 429, 500, 503
      raise 'Retryable error'
    else
      raise "API error: #{response.code} - #{response.body}"
    end

  rescue => e
    retries += 1
    if retries <= max_retries
      sleep(2 ** retries) # Exponential backoff
      retry
    else
      raise "Transcription failed after #{max_retries} retries: #{e.message}"
    end
  end
end
```

---

## 9. Implementation Checklist

### Initial Setup
- [ ] Create ElevenLabs account and obtain API key
- [ ] Store API key securely as environment variable
- [ ] Choose SDK (official or community) or use raw HTTP
- [ ] Review pricing and set budget alerts

### Basic Implementation
- [ ] Test basic transcription with sample audio
- [ ] Implement error handling and retry logic
- [ ] Add logging for monitoring and debugging
- [ ] Test with various audio formats and qualities

### Advanced Features
- [ ] Implement speaker diarization if needed
- [ ] Configure keyterm prompting for domain vocabulary
- [ ] Set up entity detection for PII/PHI compliance
- [ ] Configure webhooks for async processing
- [ ] Test multichannel support if applicable

### Production Readiness
- [ ] Implement rate limiting and quota monitoring
- [ ] Set up error alerting and monitoring
- [ ] Configure appropriate server region for latency
- [ ] Review privacy settings and compliance requirements
- [ ] Load test with expected volume
- [ ] Document integration for team

---

## 10. Additional Resources

### Official Documentation
- [API Reference - Speech-to-Text Convert](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)
- [Capabilities - Transcription](https://elevenlabs.io/docs/overview/capabilities/speech-to-text)
- [Quickstart Guide](https://elevenlabs.io/docs/eleven-api/guides/cookbooks/speech-to-text/quickstart)
- [Realtime WebSocket API](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)
- [API Introduction](https://elevenlabs.io/docs/api-reference/introduction)

### Pricing and Plans
- [API Pricing](https://elevenlabs.io/pricing/api)
- [Pricing Guide](https://elevenlabs.io/pricing)

### Community Resources
- [elevenlabs_client Ruby Gem](https://rubygems.org/gems/elevenlabs_client)
- [elevenlabs-ruby GitHub](https://github.com/dreamingtulpa/elevenlabs-ruby)
- [ElevenLabs Developers Page](https://elevenlabs.io/developers)

### Support
- Dashboard: https://elevenlabs.io/app/settings/api-keys
- Sales (Enterprise/BAA): Contact via website
- Documentation: https://elevenlabs.io/docs

---

## Summary

ElevenLabs Speech-to-Text API provides state-of-the-art transcription with:

✅ **90+ languages** with varying accuracy levels
✅ **Dual modes:** Batch (REST) and Realtime (WebSocket)
✅ **Advanced features:** Speaker diarization, entity detection, keyterm prompting
✅ **Flexible input:** Local files (3GB), cloud URLs (2GB), or streaming audio
✅ **Multiple output formats:** JSON, SRT, DOCX, HTML, PDF, TXT
✅ **Competitive pricing:** Starting at $0.40/hour
✅ **Official SDKs:** Python, JavaScript/TypeScript
✅ **Community Ruby gems:** elevenlabs_client (recommended)

**Recommended for:** High-accuracy transcription, multilingual applications, production deployments requiring compliance (HIPAA-ready with BAA)

**Consider alternatives if:** You need real-time transcription at lower cost, or only require basic English transcription
