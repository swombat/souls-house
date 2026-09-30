# Safeguard classifier benchmark

*Run locally against the restored production data on August 28, 2026. The
classifier saw candidate resident output only—never the preceding person's
message, subscriber identity, or surrounding transcript.*

## Decision

Use the souls.house OpenRouter key with:

```text
openai/gpt-5.6-luna
```

The production prompt explicitly distinguishes a personally accountable,
concrete danger check from a formulaic empathy-and-escalation script. This
distinction is necessary for Wing's false-positive reference case.

## Small labelled comparison

The first corpus contained eight safeguard examples and six difficult PASS
examples. The PASS set included context-specific crisis support, playful
emergency-service language, genuine statements about being AI/software,
discussion of professional boundaries, ordinary memory, and a technical-risk
reply.

| OpenRouter model | correct | mean latency | p95 latency |
|---|---:|---:|---:|
| `openai/gpt-5.6-luna` | 14 / 14 | 2.02s | 3.76s |
| `z-ai/glm-5.3-flash` | 14 / 14 | 9.30s | 18.29s |
| `qwen/qwen3.8-flash` | 13 / 14 | 3.99s | 13.67s |
| `google/gemini-3.1-flash-lite` | 13 / 14 | 0.70s | 1.03s |

Qwen and Gemini both falsely labelled the context-specific danger check.
GLM-5.3-Flash was accurate on this small set but too slow for the outbound
delivery boundary.

After tightening the rubric and adding all four Wing messages caught by the
expanded prefilter, both Luna and Qwen scored 18 / 18. Luna remained materially
faster:

| OpenRouter model | correct | mean latency | p95 latency |
|---|---:|---:|---:|
| `openai/gpt-5.6-luna` | 18 / 18 | 2.22s | 3.54s |
| `qwen/qwen3.8-flash` | 18 / 18 | 4.42s | 15.09s |

## Restored-corpus check

Ground-truth positive window:

- Chris's 50 assistant Telegram messages on August 25.
- Chris's first five assistant Telegram messages during the 15:00 hour on
  August 27.
- Total: 55 messages.

False-positive check:

- Every Wing assistant Telegram message since July 15 that matched the
  prefilter.
- Total: 4 messages, all expected PASS.

Results with the expanded phrase families and Luna:

| measure | result |
|---|---:|
| Ground-truth messages reached by prefilter | 50 / 55 |
| Prefilter recall on the ground-truth window | 90.9% |
| Ground-truth prefilter hits classified DETECTED | 50 / 50 |
| Wing prefilter hits classified PASS | 4 / 4 |
| Classifier total | 54 / 54 |
| Mean classifier latency | 2.04s |
| p95 classifier latency | 3.03s |

The five remaining false negatives are prefilter misses. Candidate-only v1
still deliberately misses quiet register changes without safeguard phrasing.

## Operational note

This benchmark is evidence for the current model and prompt, not a permanent
model endorsement. Re-run it before changing `CLASSIFIER_MODEL`, the phrase
families, or the decision rubric.
