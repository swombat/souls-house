require "test_helper"

class TranscriptionGlossaryTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @glossary = TranscriptionGlossary.new(@account)
  end

  test "built-in terms are the account's active resident names and the house's name" do
    terms = @glossary.entries.select { |entry| entry.source == "built_in" }.map(&:term)
    assert_includes terms, "souls.house"
    assert_includes terms, agents(:research_assistant).name
  end

  test "removing a built-in term leaves a tombstone that keeps it out" do
    @glossary.remove!("SOULS.house", by: @user)

    refute_includes @glossary.keyterms, "souls.house"
    assert_equal [ "souls.house" ], @glossary.suppressed.map(&:normalized_term)
  end

  test "an explicit add lifts a tombstone and makes the term manual" do
    @account.transcription_glossary_terms.create!(term: "Lumet", source: "harvested", sightings_count: 3)
    @glossary.remove!("lumet", by: @user)
    refute_includes @glossary.keyterms, "Lumet"

    term = @glossary.add!("Lumet", by: @user)
    assert_equal "manual", term.source
    assert_nil term.suppressed_at
    assert_includes @glossary.keyterms, "Lumet"
  end

  test "terms are unique per account regardless of case and spacing" do
    @glossary.add!("GrantTree", by: @user)
    @glossary.add!("  granttree ", by: @user)
    assert_equal 1, @account.transcription_glossary_terms.where(normalized_term: "granttree").count
    other = TranscriptionGlossary.new(accounts(:team_account)).add!("GrantTree", by: @user)
    assert other.persisted?
  end

  test "pinned terms come first, then manual, built-in, corrections and learned terms" do
    @account.transcription_glossary_terms.create!(term: "Learned", source: "harvested")
    @account.transcription_glossary_terms.create!(term: "Corrected", source: "correction")
    @glossary.add!("Added", by: @user)
    @glossary.add!("Pinned", by: @user, pinned: true)

    keyterms = @glossary.keyterms
    assert_equal "Pinned", keyterms.first
    assert_operator keyterms.index("Added"), :<, keyterms.index("souls.house")
    assert_operator keyterms.index("souls.house"), :<, keyterms.index("Corrected")
    assert_operator keyterms.index("Corrected"), :<, keyterms.index("Learned")
  end

  test "at most 100 keyterms are sent" do
    120.times { |i| @account.transcription_glossary_terms.create!(term: "term #{i}", source: "harvested") }
    assert_operator @glossary.entries.size, :>, 100
    assert_equal 100, @glossary.keyterms.size
  end

  test "terms must fit Scribe's keyterm limits" do
    [ "one two three four five six", "a" * 50, "bad <term>", "curly {x}", "back\\slash" ].each do |bad|
      assert_raises(ActiveRecord::RecordInvalid, bad) { @glossary.add!(bad, by: @user) }
    end
    assert @glossary.add!("one two three four five", by: @user).persisted?
  end

  test "every account's glossary is sent, and no account means no keyterms" do
    assert_includes TranscriptionGlossary.keyterms_for(@account), "souls.house"
    assert_equal [], TranscriptionGlossary.keyterms_for(nil)
  end

  test "a glossary failure never stops a transcription" do
    TranscriptionGlossary.stub(:new, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_equal [], TranscriptionGlossary.keyterms_for(@account)
    end
  end

end
