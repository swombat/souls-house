# Stalled-thread sweeper: dataset and evaluation (slice 1)

Build thread: BjZQAe. Product changes come in later slices; this one ships only what the sweeper will see,
the questions it will ask, and the evidence for how well it answers them.

## What is here

- `app/services/stalled_thread_snapshot.rb`: the state shown to Jev about a quiet room *as of* a time.
  The future job and the offline dataset use the same builder. A historical snapshot reads nothing created
  after its sweep time. A message discarded after the sweep time is still shown; one discarded before it is
  not. A resident seated after the sweep time is left out. A run is in progress if it started before the
  sweep time and finished after it, with no age cap. A run with no recorded finish that isn't live now is
  `"unknown"`. Pause state has no history, so it is `"unknown"` too. Handoff receipts are rebuilt as of the
  sweep time: delivered and blocked can be recovered; queued and held cannot, and show as `requested`.
  Some things cannot be rewound: message text has no edit history, and departures from a room leave no row.
  `#provenance`, kept outside the state Jev sees, lists messages updated after the sweep time and says how
  membership was reconstructed.
- `app/services/stalled_thread_classifier.rb` and `app/prompts/stalled_thread_sweep/`: one Jev `noul` question
  per resident, keyed by seat position (`can_act:1`, …) and never by name, ("can X act now on an authorised step?") plus `person_holds`. These are separate scores, so a
  room can owe a resident a step and a person an answer at the same time. Jev returns probabilities only; it
  cites no messages.
- `script/stalled_sweeper/dataset.rb`: one row for every gap of 10 minutes or more between consecutive
  messages, plus the open gap at the end of each room. The sweep time is the largest of 60, 30 or 10 minutes that falls strictly inside the gap.
  Each row has an annotation envelope of the messages that followed, for labelling only.
- `script/stalled_sweeper/holdout_chats.txt`: the held-out rooms, chosen by a fixed hash. It was committed
  before any prompt run.

Raw snapshots, labels and runs stay off git, because they hold private conversation text. The fixtures in
`test/fixtures/files/stalled_sweeper/` are synthetic rooms.

## Results (account 7, 16 Oct 2026)

### Receipt 1: before Mira's review of 9acf4983

Kept as recorded. The snapshot builder then had four boundary faults, found in that review: today's
visibility and membership, a sweep time that could equal the next message, a two-hour cap on in-progress
runs, and name-normalised question keys. Receipt 2 below is the audit after the fix.

968 snapshots across 243 rooms. 200 are excluded because a resident run was in progress at the sweep time.
Labels: Opus helpers drafted them from a written rubric. Lume reviewed every hold-out label and changed 5 to
`uncertain`. The 120 tuning-sample labels are unreviewed drafts. Uncertain rows are excluded from P/R. Rows where residents posted through user accounts (early
rooms) are reported separately. Wake is counted per (row, resident) pair; person_holds per row.

Prompt v3, frozen before the hold-out run; wake ≥ 0.8, person_holds ≥ 0.6.

| set | wake P | wake R | person_holds P | person_holds R |
|---|---|---|---|---|
| tuning sample (120 rows, 96 scored) | 1.00 (16/16) | 0.46 (16/35) | 0.82 (27/33) | 0.60 (27/45) |
| **hold-out (73 rooms, 138 scored)** | **0.96 (23/24)** | **0.50 (23/46)** | **0.94 (50/53)** | **0.64 (50/78)** |
| independent hand labels (other session's gold, 113 unseen rows) | 0.95 (19/20) | 0.56 (19/34) | 0.40 (12/30)* | 0.86 (12/14) |

\* That rubric treats "reported, next step is the person's, nothing explicitly asked" as done. This rubric
treats it as person_holds.

### Receipt 2: after the boundary fixes (same prompt v3, same thresholds, no retuning)

The dataset was re-extracted with the fixed builder: 974 rows, against 968 before (the difference is open
gaps that have appeared since, plus one historical gap created by a message discarded later). Across the
728 historical rows, compared as sets:

- 43 rows changed `residents_in_room`: a resident seated after the sweep time was removed, or a long run now
  marks the room busy.
- 2 rows changed `recent_messages`, both because of discards.
- 1 row is new.
- 0 rows had message text updated after the sweep time. 0 had a run state that could not be reconstructed.
- No gap ended exactly on a 10/30/60-minute boundary, so none was skipped.

Labelled rows affected: 1 in the hold-out (Rjpgde:YQXGqe; a run was in progress at the sweep time, so it is
now ineligible) and 15 in the tuning sample (11 of them in legacy proxy-user rooms, which are excluded from the metrics;
the tuning table comes out the same after re-scoring).
Frozen v3 re-scored the 16 changed rows. The other rows keep their original scores.

| set | wake P | wake R | person_holds P | person_holds R |
|---|---|---|---|---|
| tuning sample | 1.00 (16/16) | 0.46 (16/35) | 0.82 (27/33) | 0.60 (27/45) |
| **hold-out (137 scored, 1 now busy)** | **0.96 (22/23)** | **0.49 (22/45)** | **0.94 (50/53)** | **0.64 (50/78)** |

The person_holds numbers above use the first rubric, which counted "finished work put in front of a person"
as a hold. As of Mira's review, the definition is narrower: an explicit outstanding question, gate or action
for a person. Completion alone creates no obligation. The labels and prompt need a pass under that definition
before person_holds is anything more than a log.

The bar proposed in BjZQAe for waking was precision ≥ 0.9 with recall ≥ 0.7. Precision clears it; recall does
not. Slice 2 therefore runs in shadow (log only). Identical Jev calls vary by 0.018 on average (max 0.09).
