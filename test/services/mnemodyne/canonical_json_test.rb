require "test_helper"

class Mnemodyne::CanonicalJsonTest < ActiveSupport::TestCase

  test "normalizes nested keys without reordering arrays or mutating input" do
    input = { z: [ { b: false, a: nil }, 2, 1 ], a: { y: "value", x: true } }
    original = Marshal.load(Marshal.dump(input))

    assert_equal '{"a":{"x":true,"y":"value"},"z":[{"a":null,"b":false},2,1]}',
      JSON.generate(Mnemodyne::CanonicalJson.normalize(input))
    assert_equal original, input
  end

  test "retains the existing stringify keys collision behavior" do
    assert_equal({ "a" => 2 }, Mnemodyne::CanonicalJson.normalize({ a: 1, "a" => 2 }))
  end

  test "write digest and retries retain their existing representation" do
    vault = agents(:research_assistant).create_memory_vault!
    result = Mnemodyne::Write.call(vault: vault, key: "canonical-test", operation: "create",
      payload: { z: [ 2, 1 ], a: { b: false } }) { { "ok" => true } }

    assert_equal Digest::SHA256.hexdigest('["create",{"a":{"b":false},"z":[2,1]}]'),
      vault.operations.find_by!(key: "canonical-test").request_digest
    assert_equal result, Mnemodyne::Write.call(vault: vault, key: "canonical-test", operation: "create",
      payload: { "a" => { "b" => false }, "z" => [ 2, 1 ] }) { flunk "must reuse the recorded result" }
  end

  test "erasure fingerprint retains its existing field selection and representation" do
    envelope = { "payload" => {
      "settings" => { "z" => false, "a" => nil }, "resident_uuid" => "synthetic-resident",
      "nodes" => [ { "z" => 2, "a" => 1 } ], "edges" => [], "ignored" => "not fingerprinted"
    } }
    expected = '{"edges":[],"nodes":[{"a":1,"z":2}],"resident_uuid":"synthetic-resident","settings":{"a":null,"z":false}}'

    assert_equal Digest::SHA256.hexdigest(expected), Mnemodyne::Erasure.fingerprint(envelope)
  end

end
