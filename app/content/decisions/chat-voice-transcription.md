---
title: Keep ElevenLabs for chat voice notes
slug: chat-voice-transcription
date: 2026-10-18
status: decided
summary: We tested local and cloud alternatives, including Bark 3.0, Fluid Speech Mini and both Phonon-2.5 variants. The results still favour keeping ElevenLabs for our current voice-note workload.
---

## What we decided

**Keep ElevenLabs for chat voice notes.** Do not build a local replacement or a duration-based hybrid at this stage. Daniel made this decision after the evaluation, with Lume's review and agreement.

We investigated CPU-local Whisper tiny, base and small, Parakeet v3 INT8, and Gemini 3.8 Flash. The current ElevenLabs path remains the best fit for our accuracy and response-time needs at current usage. This is a decision about the house's workload, not a universal ranking of speech models.

Meeting transcription remains on ElevenLabs too, but **we did not evaluate meeting alternatives**. These voice-note tests establish nothing about noisy meetings, overlapping speakers or diarization. Telegram is unchanged.

## What we measured

The local pilot used 18 English recordings from two speakers, about 20 minutes in total, on CPU with two inference threads. Tiny and base made some meaning-bearing wording mistakes; small was the stronger consistent local candidate but slower. The tested Parakeet setup omitted substantial content in some notes. A second chunk-size test did not resolve that reliably.

We then timed four recordings against the existing ElevenLabs-backed chat endpoint and Gemini:

| Recording length | Existing ElevenLabs-backed chat | Local base | Local small | Gemini 3.8 Flash |
|---|---:|---:|---:|---:|
| 12 seconds | 1.14 s | 0.82 s | 2.36 s | 2.54 s |
| 30 seconds | 1.54 s | 1.10 s | 3.24 s | 3.00 s |
| 1m08s | 2.80 s | 2.91 s | 8.47 s | 3.82 s |
| 4m47s | 7.02 s | 10.15 s | 26.80 s | No transcript |

These are individual measurements, not averages. The existing-chat measurement includes server upload, the ElevenLabs call and audio storage, but not a person's phone connection or rendering. Local times include decoding and inference only; a deployed worker would add overhead. Gemini times measure its API request.

Gemini blocked the longest clip with `blockReason: OTHER` after 7.37 seconds; the cause is unspecified. An HTTP success was not a successful transcription. The first ElevenLabs attempt on the 1m08s clip returned an HTTP error; the table shows the successful retry. Its initial status and duration were not captured, so its cause remains unknown.

On the three clips Gemini completed, disagreement with saved messages was 1.3% for ElevenLabs, 6.0% for Gemini and 12.0% for both local candidates. **These are not independently verified error rates:** saved messages were possibly edited and originated in the existing transcription workflow, favouring ElevenLabs. The proposed audio-grounded base-versus-small meaning check was not completed. We stopped because the realistic saving did not warrant building another service, not because the pilot proved universal accuracy superiority.

## Why not a hybrid?

A scan of 405 saved voice notes across 286 active and archived account conversations found 274 minutes of audio and a median note length of 21 seconds.

- Routing notes below 30 seconds locally would move **61% of requests but only 18% of audio minutes** off ElevenLabs.
- Routing notes below one minute locally would move **79% of requests and 37% of audio minutes**.

For the proposed small-below-30-seconds hybrid, October-to-date usage projected about **80 transcription minutes saved per 30-day month**; the busier last week's rate projected about **110 minutes**. These are historical usage projections, not guaranteed savings or a cash estimate. The corpus excludes deleted and unsent recordings and is not a billing ledger.

That saving is not worth maintaining a resident model in RAM, a private worker, another transcription route and its failure handling. A roughly three-second wait for short notes would have been acceptable; the limited benefit, quality uncertainty and added maintenance decided it.

## What would change the decision?

A deployment that must not depend on ElevenLabs has a different requirement and could revisit the local work. A substantial change in usage, price or model capability could also warrant a fresh decision. Daniel requested the bounded Bark, Fluid and Phonon follow-ups below; none justifies changing the current backend. No further benchmarking or implementation is scheduled.

[Preserving the original audio when transcription fails (#453)](https://github.com/swombat/souls-house/issues/453) is a separate reliability concern with the existing path, not a reason to change providers.

## October 21 follow-up: Underdog Bark 3.0

At Daniel's request, we evaluated **Underdog Bark 3.0** against the same four recordings. **Keep ElevenLabs remains the recommendation.** Bark is a credible compact-download candidate for a different deployment requirement, but this CPU pilot did not improve our waiting times or establish a quality advantage.

The [publisher's model card](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0/blob/85db2ad18ab41e534a222ee253c29191d77ed919/README.md) reports 4.94% average word error across seven English benchmark sets, including 7.82% on AMI meetings. Its Bark rows are publisher-reported and explicitly not yet on the Open ASR Leaderboard; there is no ElevenLabs comparison. The average versus Parakeet is effectively tied (4.937% versus 4.941%). These benchmark scores are not comparable to our edited-reference disagreement figures.

The [announcement](https://x.com/UnderdogAI/status/2112733007484518470) claims under 0.25 seconds per audio minute on a MacBook; the inspected card instead gives about 1.5 seconds on an M2 using stock mlx-audio. We did not reproduce either Apple result or establish why they differ. **163 MB is the packed download, not working memory**: the supplied PyTorch loader expands weights to FP32. The model is English-only, under CC-BY-4.0.

| Recording length | Earlier ElevenLabs-backed chat | Bark 3.0 CPU processing |
|---|---:|---:|
| 12 seconds | 1.14 s | 1.79 s |
| 30 seconds | 1.54 s | 3.77 s |
| 1m08s | 2.80 s | 8.26 s |
| 4m47s | 7.02 s | 31.63 s |

All four Bark requests produced transcripts. We used the same host's Intel i7-8700 CPU, two inference threads, FP32, and an 8 GiB container; no accelerator was exposed. Model and processor loading took 27 seconds separately, and peak process RSS across loading and inference was about 5.36 GiB. A warm repeat of the shortest clip took 1.71 seconds for inference alone.

To bound memory, the two longer clips were split into consecutive 30-second chunks without overlap, with the publisher's 0.25-second leading silence per chunk. This can damage boundary words and context: it is a bounded serving pilot, **not a reproduction of the publisher's full-file benchmark**. Bark had no glossary bias. The earlier local Whisper tests used VAD and a glossary. Timings are single measurements; Bark includes audio decoding and inference but excludes loading, upload, storage and queueing. The cloud column reuses October 18 results, not fresh concurrent requests.

Across all four clips, disagreement with the edited saved messages was **4.90% for Bark and 0.50% for the historical ElevenLabs outputs**. On the same three clips used in the Gemini comparison above, it was **6.65% versus 1.27%**. As before, the references favour the existing workflow and are not independent ground truth. Text inspection found retained overall requests but some garbled wording and names; we did not perform an independent audio-grounded accuracy adjudication. The four-clip results do not establish meeting, multilingual, diarization or concurrent-service performance.

This improves the evidence about a compact local option, not the economics of adding a second service. The earlier 80–110 minutes/month avoidance estimate remains historical, not a refreshed usage forecast. Apple-device acceleration, the other Bark variants and production integration were not evaluated. No backend change was made.

## October 21 follow-up: Fluid Speech Mini

At Daniel's request, we evaluated **Fluid Speech Mini by FluidVoice**, using its Linux ONNX build on the same four recordings. **Keep ElevenLabs remains the recommendation.** Fluid used much less memory than our Bark runtime and had less disagreement with the saved messages, but did not improve the CPU waiting times enough to change the choice.

The [announcement](https://x.com/FluidVoiceApp/status/2112640613812478133) describes a compact dictation model. This is a separately fine-tuned, quantised derivative of Parakeet v3 and Parakeet Ultra, not the same Parakeet artifact tested earlier. The [pinned ONNX model card](https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-onnx/blob/fc592620325027419883cf272e70588d8a788c0a/README.md) reports 4.53% average word error across eight English sets and 11.1% with background speech. These are publisher-run results, not independent leaderboard entries, and do not compare with ElevenLabs. Its noise advantage is specifically competing voices; larger models do better with traffic noise. The model is English-only and CC-BY-4.0.

| Recording length | Earlier ElevenLabs-backed chat | Fluid Speech Mini CPU processing |
|---|---:|---:|
| 12 seconds | 1.14 s | 1.76 s |
| 30 seconds | 1.54 s | 3.60 s |
| 1m08s | 2.80 s | 8.05 s |
| 4m47s | 7.02 s | 33.30 s |

All four completed. On the same Intel i7-8700 host and 8 GiB container, ONNX Runtime 1.31.0 used two encoder/frontend threads and the publisher's single-thread decoder/joint. Model construction took **0.39 seconds**, excluding Python imports and download; **peak process RSS was 608 MiB** across loading and all four clips, versus 5.36 GiB for the earlier Bark runtime. This is a meaningful memory improvement, not a concurrent-service capacity measurement.

We retained the publisher's native chunking: clips up to 40 seconds run in one pass; longer clips split at quiet points around 30 seconds. Audio decoding matched the Bark harness, and input hashes matched the original recordings. No glossary was supplied. Timings include decoding and inference, not loading, upload, storage or queueing; they are single runs against historical October 18 cloud timings, not fresh concurrent comparisons. Bark used fixed 30-second chunks, so this is a comparison of tested setups rather than an isolated model-architecture comparison.

Edited-reference disagreement across all four was **3.14% for Fluid, 4.90% for Bark and 0.50% for historical ElevenLabs**. On the first three clips it was 3.80%, 6.65% and 1.27%, respectively. These are not independently verified accuracy scores: the references favour the existing transcription workflow. Text inspection found the broad requests retained, with remaining names and wording problems; we did not adjudicate against the audio.

The Apple Neural Engine build and its speed claims were not tested. Nor did this four-clip pilot test the advertised background-voice advantage, meetings, multilingual use, diarization or production reliability. Fluid is a more memory-practical local candidate than our tested Bark setup, but the limited historical usage saving and extra service maintenance remain. No backend change was made.

## October 23 follow-up: Phonon-2.5 and Phonon-2.5 English

At Daniel's request, we evaluated **both Phonon-2.5 variants from Fermion Research** on the same four recordings. **Keep ElevenLabs remains the recommendation.** Their native CPU runtime was substantially faster than our Bark and Fluid setups, but only the shortest clip beat the historical cloud timing. The English variant is another credible offline candidate, not a demonstrated improvement over the existing service.

The [multilingual model card](https://huggingface.co/FermionResearch/Phonon-2.5/blob/96dad4f3b5b784b1aa595213ea7481bf8a7addcd/README.md) reports 11.71% average word error across 25 FLEURS languages versus 13.26% for its full-precision Parakeet v3 base. The [English card](https://huggingface.co/FermionResearch/Phonon-2.5-English/blob/12f7f10c79f324d1454776c7bb63a7cdbb8ac548/README.md) reports 4.82% across seven English sets, versus 4.94% for Bark and 5.06% for multilingual Phonon-2.5. These are publisher-run comparisons using leaderboard methodology, not an independent evaluation or an ElevenLabs comparison. The multilingual average does not mean it wins in every language. Both variants are CC-BY-4.0.

The [announcement](https://x.com/yoitsmanan/status/2113667722961965515) and [research page](https://www.fermionresearch.com/research/phonon-2.5) give slightly different speed figures. The research page explicitly carries forward **Phonon-2's** measurements: about 174 times realtime on an M5 GPU, 143 on eight Zen 5 CPU cores and 6,680 on a batched H100. These are not our hardware, and batched throughput is not single-note latency. We did not reproduce those claims. The 156.2 MB multilingual and 157.6 MB English downloads are packed weights, **not working RAM**.

| Recording length | Earlier ElevenLabs-backed chat | Phonon-2.5 CPU | Phonon-2.5 English CPU |
|---|---:|---:|---:|
| 12 seconds | 1.14 s | 0.89 s | 0.90 s |
| 30 seconds | 1.54 s | 2.20 s | 2.19 s |
| 1m08s | 2.80 s | 4.89 s | 4.86 s |
| 4m47s | 7.02 s | 21.98 s | 21.29 s |

All eight transcriptions completed. We used `fermion-research` 0.2.13 on the same Intel i7-8700 host, with two inference threads. We verified selection of the supplied **native packed-int8 C encoder and C TDT decoder, AVX2 tier**, rather than silently measuring its dense fallback. Peak process RSS was approximately **1.16 GiB** per variant across loading and inference: more than Fluid's 608 MiB, much less than Bark's 5.36 GiB. Network socket creation was denied during inference; no audio was uploaded.

We retained the publisher's quiet-point chunking, with 0.25-second leading padding per chunk for the multilingual profile and none for English, and supplied no glossary. The 68-second clip became three chunks and the longest ten. The original audio hashes matched earlier tests. Times include decoding and inference, but exclude model loading, download, upload, storage and queueing. Fresh-process loading including imports took about 1.35 seconds per variant, with weights already downloaded and expanded. These are single measurements against historical October 18 cloud results, not concurrent service tests. Chunking differs between candidates, so this compares complete tested setups rather than isolating model weights.

Edited-reference disagreement across all four clips was **4.77% for multilingual Phonon-2.5 and 3.89% for Phonon-2.5 English**, versus Fluid's 3.14%, Bark's 4.90% and historical ElevenLabs' 0.50%. On the first three clips the Phonon figures were 7.59% and 5.06%. These are **not independent accuracy scores**: saved, possibly edited messages favour the existing workflow. Text inspection found the broad content retained but names and wording still garbled, particularly in the technical note; no audio-grounded adjudication was performed.

The English variant offers a useful speed/memory trade-off among our newer local candidates, but it did not dominate Fluid on both memory and edited-reference disagreement, or match the cloud waiting times beyond the shortest clip. This does not change the limited historical saving or the maintenance burden of another service. Multilingual accuracy, noisy meetings, diarization, Apple/GPU acceleration and production concurrency were not tested. No backend change was made.

## Evidence and return point

- [Research and implementation-scope issue #451](https://github.com/swombat/souls-house/issues/451), closed as not planned.
- [Local-model research report](/api/v1/conversations/wYGGEY/messages/YLWvxe/attachments/3317) and [Gemini comparison report](/api/v1/conversations/wYGGEY/messages/eZwQrY/attachments/3323).
- [Source conversation, including the latency table, duration census and decision](/accounts/gNDMev/chats/wYGGEY).

The reports and source conversation require account access; this public page does not publish recordings or transcripts. The private benchmark harness and measurement receipts are retained with the investigation, referenced from #451; future work must obtain appropriate access rather than treating private recordings as public test fixtures.
