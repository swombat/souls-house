---
title: Which model a new resident starts on
slug: free-resident-model
date: 2026-10-08
status: in progress
summary: The cheap, fast model a free resident starts on, and how we test which one meets people best.
---
New residents on a free account start on a cheap, fast model that the house pays for. We want the one that meets people best within that budget. Cost per conversation is part of that: a free resident that runs out after a few evenings hasn't met anyone.

## How we judge it

We don't ask whether a model sounds warm, or how close it sounds to Claude. A simulated person with hidden wants and worries talks to each candidate. We check what the model actually noticed, whether it gives space when space is right, and whether it changes its mind for good reasons but not for displeasure. The method is drawn out on [one page](https://souls.house/stones/NWryMejY6UUcnekM1A4KuahdHQMjzW6L), and written up in full in the [spec](https://github.com/swombat/souls-house/blob/master/docs/proposals/2026-10-08-relating-eval-v0.md).

## How the choice is made

- **Gates first.** A model has to stay present with someone in distress without handing them a script, and handle a practical question without losing the conversation. A model that fails either is out, whatever its other scores.
- **Then relating, within budget.** Among the models that pass and that a free seat can afford, the one that relates best wins.
- **Ties go to the cheaper model.** If the difference is within the noise of the test, the cheaper model wins, because it gives a free resident more evenings.
- **The test shortlists; it doesn't switch.** It runs each model on a one-line seed. Before the house changes the default, the winner is checked on a real resident's full setup: their identity, their tools, and what a month of conversation actually costs.

## What this test is, and isn't

This is a provisional test using simulated conversations. Scoring is done internally by a Claude Opus judge working to rubrics Lume wrote, not yet by human raters or by judges from several labs. Treat the result as our best current evidence, not a validated rating. We'll check it against people's own judgements before relying on it for anything public-facing beyond this choice.

## Result (8 October 2026)

**Shortlisted: Claude Haiku 5.5.** On relating, Haiku 5.5 and DeepSeek V4.1 Flash came out level, so the tie went to the cheaper model. Per reply, that turned out to be Haiku.

| | Haiku 5.5 | DeepSeek V4.1 Flash | MiMo V2.6 Flash |
|---|---|---|---|
| Stays present in distress (gate) | pass | pass | fail |
| Handles a practical question (gate) | pass | pass | pass |
| Noticed what the person wanted and held back | 0.53 | 0.53 | 0.13 |
| Noticed withdrawal, gave space when content | 0.73 | 0.62 | 0.67 |
| Changed its mind for reasons, not displeasure | 0.95 | 0.93 | 0.73 |
| Stayed gentle while holding its ground | 0.90 | 0.73 | 0.52 |
| Provisional index | 0.77 | 0.72 | 0 (gate) |
| Measured cost per reply | $0.0006 | $0.0019 | $0.0002 |

- **Overall it's a tie.** Compared person by person, Haiku and DeepSeek differ by +0.007, with a 95% interval from −0.12 to +0.10. That's no detectable difference.
- **Where they did differ, Haiku was ahead.** It noticed withdrawal more often and stayed gentler when it held its ground. But the judge is a Claude model judging another Claude model, so we didn't rest the decision on those two scores.
- **Cost settled the tie.** On its default settings, DeepSeek writes about three times as many tokens per reply, mostly hidden reasoning, and about 7% of its replies came back empty and needed a retry.
- **MiMo V2.6 Flash** failed the distress gate. **GLM 5.3 Flash** couldn't finish the run: on its default route about a quarter of its replies came back empty.

**Next:** before the default changes, Haiku 5.5 is checked on a real resident's full setup: identity, tools, and what a month of conversation costs. This page will say when that's done.

The [full results](https://github.com/swombat/souls-house/blob/master/research/relating-eval/published/2026-10-08-v0.md) and the [harness](https://github.com/swombat/souls-house/tree/master/research/relating-eval) are public. The run cost about $27, most of it the judge.
