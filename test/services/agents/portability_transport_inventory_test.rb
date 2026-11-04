require "test_helper"

# #426 slice 3C: the runtime inventory reads only what its script prints.
class Agents::PortabilityTransportInventoryTest < ActiveSupport::TestCase

  Transport = Agents::Portability::Transport
  Error = Agents::Portability::Error
  PROBES = Transport::INVENTORY_PROBES.fetch(:chaos)

  test "parses sizes, the named paths present and the session map's entry count" do
    found = Transport.parse_inventory("files 12\nbytes 25769803776\nhas chaos.sqlite\nhas oauth-runtime/chaos.sqlite\nsessions 3\n", PROBES)
    assert_equal({ files: 12, bytes: 25_769_803_776, present: %w[chaos.sqlite oauth-runtime/chaos.sqlite], sessions: 3 }, found)
    assert_nil Transport.parse_inventory("files 0\nbytes 0\n", PROBES)[:sessions], "no session map is not zero sessions"
  end

  test "refuses anything it did not ask for, rather than guessing" do
    [ "files 1\n", "bytes 1\n", "files 1\nbytes 1\nhas ../../etc\n", "files 1\nbytes 1\nhas secrets.txt\n",
      "files 1\nbytes 1\nsomething else\n", "files -1\nbytes 1\n",
      "files 12\nbytes 1\nfiles 0\n", "files 1\nbytes 1\nbytes 0\n", "files 1\nbytes 1\nsessions 3\nsessions 0\n",
      "files 1\nbytes 1\nhas chaos.sqlite\nhas chaos.sqlite\n" ].each do |text|
      error = assert_raises(Error, text) { Transport.parse_inventory(text, PROBES) }
      assert_equal "Resident runtime state cannot be measured", error.message
    end
  end

  test "the script fails on any failed traversal or stat, and prints sizes, never names" do
    script = Transport::INVENTORY_SCRIPT
    assert_equal "set -eo pipefail", script.lines.first.strip
    assert_includes script, "-exec stat -c %s {} +"
    assert_includes script, "-exec stat -c x {} + | wc -l", "one line per session file whatever its name"
    assert_not_includes script, "-print"
    assert_not_includes script, "-type f | wc -l"
  end

  test "only the Chaos and state volumes can be inventoried" do
    error = assert_raises(Error) { Transport.new(Agent.new).inventory(:identity) }
    assert_equal "Unsupported runtime volume", error.message
  end

end
