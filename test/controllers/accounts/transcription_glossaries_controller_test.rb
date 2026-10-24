require "test_helper"

class Accounts::TranscriptionGlossariesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  test "a member sees the glossary with built-in terms" do
    get account_transcription_glossary_path(@account), headers: {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest
    }

    assert_response :success
    terms = inertia_shared_props.fetch("terms").map { |term| term.fetch("term") }
    assert_includes terms, "souls.house"
    assert_equal 100, inertia_shared_props.fetch("keyterm_limit")
  end

  test "a member adds, pins and removes a term, and the removal sticks" do
    post account_transcription_glossary_path(@account), params: { term: "GrantTree" }
    assert_redirected_to account_transcription_glossary_path(@account)
    record = @account.transcription_glossary_terms.find_by!(normalized_term: "granttree")
    assert_equal @user, record.created_by_user

    patch account_transcription_glossary_path(@account), params: { term: "granttree", pinned: true }
    assert record.reload.pinned

    delete account_transcription_glossary_path(@account), params: { term: "GrantTree" }
    assert record.reload.suppressed?
    refute record.pinned
    refute_includes TranscriptionGlossary.new(@account).keyterms, "GrantTree"
  end

  test "pinning a built-in term gives it a row" do
    patch account_transcription_glossary_path(@account), params: { term: "souls.house", pinned: true }

    record = @account.transcription_glossary_terms.find_by!(normalized_term: "souls.house")
    assert record.pinned
    assert_equal "souls.house", TranscriptionGlossary.new(@account).keyterms.first
  end

  test "an invalid term is refused" do
    post account_transcription_glossary_path(@account), params: { term: "one two three four five six" }

    assert_redirected_to account_transcription_glossary_path(@account)
    assert_empty @account.transcription_glossary_terms
  end

  test "someone outside the account can't see or change its glossary" do
    other = accounts(:other)

    get account_transcription_glossary_path(other)
    assert_response :not_found
    post account_transcription_glossary_path(other), params: { term: "Leak" }
    assert_response :not_found
    assert_empty other.transcription_glossary_terms
  end

  test "navbar partial evaluates neither glossary builder" do
    glossary = TranscriptionGlossary.new(@account)
    glossary.stub(:entries, -> { flunk "terms evaluated" }) do
      glossary.stub(:suppressed, -> { flunk "removed evaluated" }) do
        TranscriptionGlossary.stub(:new, glossary) do
          %w[account room_activity accounts,expired_subscriptions reply_attention rooms,current_room].each do |props|
            partial_get(props)
            assert_not response.parsed_body.fetch("props").key?("terms")
            assert_not response.parsed_body.fetch("props").key?("removed")
          end
        end
      end
    end
  end

  test "terms and removed are independently lazy" do
    glossary = TranscriptionGlossary.new(@account)
    glossary.stub(:suppressed, -> { flunk "removed evaluated for terms" }) do
      TranscriptionGlossary.stub(:new, glossary) { partial_get("terms") }
    end
    assert response.parsed_body.fetch("props").key?("terms")
    assert_not response.parsed_body.fetch("props").key?("removed")
    glossary.stub(:entries, -> { flunk "terms evaluated for removed" }) do
      TranscriptionGlossary.stub(:new, glossary) { partial_get("removed") }
    end
    assert response.parsed_body.fetch("props").key?("removed")
    assert_not response.parsed_body.fetch("props").key?("terms")
  end

  private

  def partial_get(props)
    get account_transcription_glossary_path(@account), headers: {
      "X-Inertia" => "true",
      "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => "accounts/transcription_glossary",
      "X-Inertia-Partial-Data" => props
    }
    assert_response :success
  end

end
