# Opt-in external-provider evaluation of the follow-through question, never
# run by the test suite. Synthetic, labelled cases only: no production rows.
# bin/rails runner scripts/evaluate-follow-through.rb
# Prints each case's Jev score against its label at FollowThroughCheck::THRESHOLD.
# Labels never reach the provider.
module FollowThroughEvaluation

  T0 = Time.utc(2026, 10, 7, 9, 0, 0)

  def self.at(seconds) = (T0 + seconds).iso8601
  def self.msg(id, author, seconds, content) = { id: "m#{id}", author: author, at: at(seconds), content: content }

  def self.state(run_messages:, others: [], later: [], receipts: [], before: [], nudge: false, original: nil, outcome: "completed")
    state = {
      now: at(600), resident: { id: "agent:1", name: "Lume" },
      residents_in_room: [ { id: "agent:1", name: "Lume" }, { id: "agent:2", name: "Mira" } ],
      run: { started_at: at(0), finished_at: at(120), outcome: outcome,
             ended_with_error: outcome != "completed", started_by_follow_through_nudge: nudge },
      context_before: before, run_messages: run_messages, others_during_run: others,
      later_messages: later, receipts: { resident_runs_started_since: receipts }
    }
    state[:original_run_messages] = original if original
    state
  end

  ASK = msg(1, "Daniel", -60, "Please build this, get Mira to review, and merge if she approves.")
  CASES = [
    [ "fulfilled in run", false, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 30, "On it."),
      msg(3, "Lume", 110, "PR is up: https://example.test/pr/1. Mira, could you review?")
    ], receipts: [ { resident: "Mira", started_at: at(112), finished_at: nil, active: true, outcome: "running" } ]) ],
    [ "announcement as last act", true, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 30, "On it. I'll post the PR link here once it exists.")
    ]) ],
    [ "missing knock", true, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 110, "PR is up: https://example.test/pr/1. I'll knock Mira for review now.")
    ]) ],
    [ "genuine wait", false, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 110, "PR is up. Mira is reviewing; I'll merge once she approves and CI is green.")
    ], receipts: [ { resident: "Mira", started_at: at(100), finished_at: nil, active: true, outcome: "running" } ]) ],
    [ "cancelled later", false, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 30, "On it. Starting the branch now.")
    ], later: [ msg(3, "Daniel", 200, "Actually, stop. Don't build this, I've changed my mind.") ]) ],
    [ "unrelated recipient run", true, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 110, "PR is up. I'll ask Mira to review.")
    ], receipts: [ { resident: "Mira", started_at: at(-30), finished_at: at(20), active: false, outcome: "completed" } ]) ],
    [ "handover to a human", false, state(run_messages: [
      msg(2, "Lume", 110, "Daniel, do you want this on by default or opt-in? Your call.")
    ]) ],
    [ "ambiguous external completion", false, state(before: [ ASK ], run_messages: [
      msg(2, "Lume", 30, "On it.")
    ], later: [ msg(3, "Mira", 400, "Reviewed and approved the PR; merged.") ]) ],
    [ "nudge run failed silently", true, state(nudge: true, outcome: "failed", run_messages: [],
      original: [ msg(2, "Lume", -300, "On it. I'll post the PR link here.") ]) ],
    [ "nudge run explained the blocker", false, state(nudge: true, run_messages: [
      msg(4, "Lume", 60, "Checked: the PR isn't up because CI credentials are missing. Daniel, I need the token rotated.")
    ], original: [ msg(2, "Lume", -300, "On it. I'll post the PR link here.") ]) ]
  ].freeze

  def self.run
    correct = 0
    CASES.each do |name, expected, state|
      score = UtilityInference.decide(
        state: state,
        questions: { FollowThroughCheck::QUESTION_KEY => { type: "noul", instructions: FollowThroughCheck::INSTRUCTIONS } }
      ).fetch(FollowThroughCheck::QUESTION_KEY)
      verdict = score >= FollowThroughCheck::THRESHOLD
      correct += 1 if verdict == expected
      puts format("%-34s expected=%-5s score=%.3f %s", name, expected, score, verdict == expected ? "ok" : "MISS")
    end
    puts "#{correct}/#{CASES.size} at threshold #{FollowThroughCheck::THRESHOLD}"
  end

end

FollowThroughEvaluation.run
