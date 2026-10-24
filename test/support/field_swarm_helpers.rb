# Field swarm tests: tagged notes and a reader stand-in. No live calls.
module FieldSwarmHelpers

  USAGE = { "prompt_tokens" => 1_000, "completion_tokens" => 50, "cost" => 0.000125 }.freeze

  def tagged_note(account, name, content, tag: "research", by: users(:user_1))
    note = account.whiteboards.create!(name: name, content: content)
    FieldTagging.create!(account: account, field_tag: FieldTag.named!(account, tag, by: by), taggable: note, tagged_by: by)
    note
  end

  # Runs the block with `reader` (a lambda taking the reader's keywords and
  # returning { text:, usage:, id: }) in place of the live one.
  def with_reader(reader)
    previous = FieldSwarm.reader
    FieldSwarm.reader = reader
    yield
  ensure
    FieldSwarm.reader = previous
  end

  def answer(verdict, extract: "", why: "", quotes: [], usage: USAGE)
    { text: { verdict: verdict, extract: extract, why: why, quotes: quotes }.to_json, usage: usage, id: "gen-#{SecureRandom.hex(4)}" }
  end

  # The <material> the reader was given.
  def material(user) = user[%r{<material>\n(.*)\n</material>}m, 1]

end
