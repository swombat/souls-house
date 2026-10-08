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

## Result

The first run is in progress: Claude Haiku 5.5 against DeepSeek V4.1 Flash, with two reference models from an earlier test. Results, and the decision, will appear here.
