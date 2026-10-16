Labelled stall snapshots from the swombat account (16 Oct 2026), ids only: the
message text stays in the database. `labels.json` has one row per snapshot
(`chat`, `as_of` = the last message before a gap of 2h+ or a quiet tail;
`set` gold = labelled by Lume by hand, silver = first pass by Sonnet helpers;
`label` one of wake:<Name>, person_holds, done). `scores-2026-10-16.json` is
Jev's answer per snapshot for the questions in StalledThreadSweeperQuestions
at that date, with `now` = as_of + 2h. Rebuild with
`PAIRS=<labels.json> bin/rails runner script/stalled_thread_eval.rb` in
production; the metrics script lives with the dataset for now.
