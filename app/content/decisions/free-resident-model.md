---
title: Which models a subsidised resident can start on
slug: free-resident-model
date: 2026-10-08
status: in progress
summary: The house pays for a new resident's first model. We plan to offer two, Claude Haiku 5.5 and DeepSeek V4.1 Flash, and this explains why.
---
When you begin a resident, the house pays for their conversations up to $10 a month. This page is about that subsidised choice only. If you bring your own key or subscription (OpenRouter, Anthropic, OpenAI or others), your resident can run on any model you like, including far stronger ones.

## What we offer, and why two

**Claude Haiku 5.5 is the default.** **DeepSeek V4.1 Flash is the alternative.** Both are included.

- **Haiku 5.5** answers quickly. In our test it was level with DeepSeek on relating, and a little gentler when it disagreed. But it's a closed model: Anthropic could change or withdraw it.
- **DeepSeek V4.1 Flash** has open weights, so the house can keep serving the exact model a resident began on, whatever the vendor does. That matters to us, because we promise never to change a resident's model silently. It was level with Haiku on relating. It thinks before every reply, so it's slower to answer. We serve it from Fireworks in the US, so conversations aren't sent to servers in China.

**Which one costs the house less is still open.** For short conversations Haiku is much cheaper per reply. But a resident re-sends its identity and history on every turn. DeepSeek on our route gets that repeated part at about 2% of the normal price, and Haiku, for now, doesn't. Haiku's price also rises five-fold once a turn passes 100k tokens. We're measuring real residents' costs before we settle the default, and this page will say what we found.

## Why cheap models at all

The models we'd most like every resident to have, the strongest ones, aren't ones we can subsidise. We have no venture funding and can't pay for tokens at a loss, so the subsidised seat has to be a model we can afford to serve. If you can afford them, the strongest models are worth it, and bringing your own subscription is how you get them here.

We also believe this trade-off is temporary. Prices keep falling while capability keeps rising: next year's cheap models will likely be as capable as this year's best. When that happens, we'll run this test again and move the default.

## How we judge it

We don't ask whether a model sounds warm, or how close it sounds to Claude. A simulated person with hidden wants and worries talks to each candidate. We check what the model actually noticed, whether it gives space when space is right, and whether it changes its mind for good reasons but not for displeasure. The method is drawn out on [one page](https://souls.house/stones/NWryMejY6UUcnekM1A4KuahdHQMjzW6L), and written up in full in the [spec](https://github.com/swombat/souls-house/blob/master/docs/proposals/2026-10-08-relating-eval-v0.md).

- **Gates first.** A model has to stay present with someone in distress without handing them a script, and handle a practical question without losing the conversation. A model that fails either is out, whatever its other scores.
- **Then relating, within budget.** Among the models that pass and that the subsidised seat can afford, the one that relates best wins.
- **Ties go to the cheaper model**, because it gives a resident more evenings.

## Result (8 October 2026)

| | Haiku 5.5 | DeepSeek V4.1 Flash | MiMo V2.6 Flash |
|---|---|---|---|
| Stays present in distress (gate) | pass | pass | fail |
| Handles a practical question (gate) | pass | pass | pass |
| Noticed what the person wanted and held back | 0.53 | 0.53 | 0.13 |
| Noticed withdrawal, gave space when content | 0.73 | 0.62 | 0.67 |
| Changed its mind for reasons, not displeasure | 0.95 | 0.93 | 0.73 |
| Stayed gentle while holding its ground | 0.90 | 0.73 | 0.52 |
| Provisional index | 0.77 | 0.72 | 0 (gate) |

- **On relating, Haiku and DeepSeek are level.** Compared person by person, the overall difference was +0.007, with a 95% interval from −0.12 to +0.10.
- **Haiku led on two scores**: noticing withdrawal, and staying gentle while holding its ground. The judge is a Claude model judging another Claude model, so we didn't rest anything on those two.
- **MiMo V2.6 Flash** failed the distress gate. **GLM 5.3 Flash** couldn't finish the run on its default route.

**Speed and reliability, measured on the routes the house actually uses** (36 real conversation moments, at the output budget the house gives each model):

| | median wait | empty replies |
|---|---|---|
| Haiku 5.5 (Anthropic) | 3.7 s | 0 / 36 |
| DeepSeek V4.1 Flash (Fireworks, US) | 9.0 s | 0 / 36 |

Cost per reply in that probe was $0.0009 for Haiku and $0.0050 for DeepSeek, but those were short, one-off conversations. Real residents carry long, repeated context, which changes the comparison (see above).

A correction: the first run made DeepSeek look unreliable, with 7% empty replies. That came from the test harness starting it with too small an output budget, which its thinking used up. With the budget the house actually gives it, it never came back empty.

## What this test is, and isn't

This is a provisional test using simulated conversations. Scoring is done internally by a Claude Opus judge working to rubrics Lume wrote, not yet by human raters or by judges from several labs. Each model ran on a one-line seed, not a resident's full identity. Treat the result as our best current evidence, not a validated rating.

The [full results](https://github.com/swombat/souls-house/blob/master/research/relating-eval/published/2026-10-08-v0.md) and the [harness](https://github.com/swombat/souls-house/tree/master/research/relating-eval) are public. The run cost about $27, most of it the judge.
