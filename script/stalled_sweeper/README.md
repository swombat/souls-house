# Stalled-thread sweeper: dataset and evaluation (slice 1)

Build thread: BjZQAe. Product changes come in later slices; this one ships only what the sweeper will see,
the questions it will ask, and the evidence for how well it answers them.

## What is here

- `app/services/stalled_thread_snapshot.rb`: the state shown to Jev about a quiet room *as of* a time.
  The future job and the offline dataset use the same builder. A historical snapshot reads nothing created
  after its sweep time. Pause state has no history, so it is `"unknown"` there. Handoff receipts are rebuilt
  as of the sweep time: delivered and blocked can be recovered; queued and held cannot, and show as
  `requested`.
- `app/services/stalled_thread_classifier.rb` and `app/prompts/stalled_thread_sweep/`: one Jev `noul` question
  per resident ("can X act now on an authorised step?") plus `person_holds`. These are separate scores, so a
  room can owe a resident a step and a person an answer at the same time. Jev returns probabilities only; it
  cites no messages.
- `script/stalled_sweeper/dataset.rb`: one row for every gap of 10 minutes or more between consecutive
  messages, plus the open gap at the end of each room. The sweep time is 10, 30 or 60 minutes into the gap.
  Each row has an annotation envelope of the messages that followed, for labelling only.
- `script/stalled_sweeper/holdout_chats.txt`: the held-out rooms, chosen by a fixed hash. It was committed
  before any prompt run.

Raw snapshots, labels and runs stay off git, because they hold private conversation text. The fixtures in
`test/fixtures/files/stalled_sweeper/` are synthetic rooms.

## Results (account 7, 16 Oct 2026)

968 snapshots across 243 rooms. 200 are excluded because a resident run was in progress at the sweep time.
Labels: Opus helpers drafted them from a written rubric and Lume reviewed every one; 5 were changed to
`uncertain`. Uncertain rows are excluded from P/R. Rows where residents posted through user accounts (early
rooms) are reported separately. Wake is counted per (row, resident) pair; person_holds per row.

Prompt v3, frozen before the hold-out run; wake ≥ 0.8, person_holds ≥ 0.6.

| set | wake P | wake R | person_holds P | person_holds R |
|---|---|---|---|---|
| tuning sample (120 rows, 96 scored) | 1.00 (16/16) | 0.46 (16/35) | 0.82 (27/33) | 0.60 (27/45) |
| **hold-out (73 rooms, 138 scored)** | **0.96 (23/24)** | **0.50 (23/46)** | **0.94 (50/53)** | **0.64 (50/78)** |
| independent hand labels (other session's gold, 113 unseen rows) | 0.95 (19/20) | 0.56 (19/34) | 0.40 (12/30)* | 0.86 (12/14) |

\* That rubric treats "reported, next step is the person's, nothing explicitly asked" as done. This rubric
treats it as person_holds.

The bar proposed in BjZQAe for waking was precision ≥ 0.9 with recall ≥ 0.7. Precision clears it; recall does
not. Slice 2 therefore runs in shadow (log only). Identical Jev calls vary by 0.018 on average (max 0.09).
