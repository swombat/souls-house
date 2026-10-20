require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingSpeakersControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
    @first, @second = @recording.speakers.to_a
  end

  def name_speaker(speaker, recording: @recording, **attributes)
    patch account_field_recording_speaker_path(@account, recording, speaker), params: { speaker: attributes }
  end

  test "'You' links the speaker to the current user's own voice" do
    name_speaker(@first, me: true)

    assert_redirected_to account_field_recording_path(@account, @recording)
    voice = @first.reload.field_voice
    assert_equal @user, voice.user
    assert_equal "human", @first.naming_source
    assert_equal @user, @first.named_by
    assert_match "#{voice.name}: hello", @recording.reload.transcript_text
  end

  test "a new name makes a voice for this speaker only" do
    other = ready_recording(account: @account, user: @user)
    name_speaker(@second, name: "Priya")

    assert_equal "Priya", @second.reload.display_name
    assert_match "Speaker 2: there", other.reload.transcript_text
    assert_match "Priya: there", @recording.reload.transcript_text
  end

  test "a name that matches an existing voice asks before linking" do
    priya = @account.field_voices.create!(name: "Priya")
    @second.name_as!(priya, by: @user)
    later = ready_recording(account: @account, user: @user)

    name_speaker(later.speakers.first, recording: later, name: "priya")
    assert_nil later.speakers.first.reload.field_voice
    follow_redirect!
    @inertia_props = nil
    match = JSON.parse(inertia_props.dig("props", "errors", "name_match"))
    assert_equal priya.to_param, match["voice_id"]
    assert_equal "Board call", match["last_named_in"]

    name_speaker(later.speakers.first, recording: later, name: "priya", link_existing: true)
    assert_equal priya, later.speakers.first.reload.field_voice
  end

  test "an existing voice or a member can be chosen" do
    voice = @account.field_voices.create!(name: "Tomás")
    name_speaker(@first, voice_id: voice.to_param)
    assert_equal voice, @first.reload.field_voice

    name_speaker(@second, member_user_id: @user.id)
    assert_equal @user, @second.reload.field_voice.user
  end

  test "un-naming returns the speaker to 'Speaker N'" do
    name_speaker(@first, name: "Priya")
    name_speaker(@first, unname: true)

    assert_nil @first.reload.field_voice
    assert_match "Speaker 1: hello", @recording.reload.transcript_text
  end

  test "a card for one voice heard as two speakers names and un-names them together" do
    ioan = @account.field_voices.create!(name: "Ioan")
    [ @first, @second ].each { |speaker| speaker.name_as!(ioan, by: @user) }
    daniel = @account.field_voices.create!(name: "Daniel")

    name_speaker(@first, voice_id: daniel.to_param, with: [ @second.to_param ])
    assert_equal [ daniel, daniel ], [ @first.reload.field_voice, @second.reload.field_voice ]

    name_speaker(@first, unname: true, with: [ @second.to_param ])
    assert_nil @first.reload.field_voice
    assert_nil @second.reload.field_voice
  end

  test "with reaches only speakers linked to the same voice on this recording" do
    ioan = @account.field_voices.create!(name: "Ioan")
    @first.name_as!(ioan, by: @user)
    other = ready_recording(account: @account, user: @user, title: "Other call").speakers.first
    other.name_as!(ioan, by: @user)

    name_speaker(@first, unname: true, with: [ @second.to_param, other.to_param ])
    assert_nil @first.reload.field_voice
    assert_equal ioan, other.reload.field_voice, "another recording is out of reach"
    assert_nil @second.reload.field_voice_id
  end

  test "transcript text joins consecutive turns of one voice heard as two speakers" do
    ioan = @account.field_voices.create!(name: "Ioan")
    [ @first, @second ].each { |speaker| speaker.name_as!(ioan, by: @user) }
    assert_equal 1, @recording.reload.transcript_text.lines.size
  end

  # Runs `correction` once, just before the merged request takes its locks:
  # another request that finished while this one was on its way.
  def with_correction_before_locks(correction)
    original = FieldVoiceprints::Locks.method(:with)
    pending = correction
    FieldVoiceprints::Locks.stub(:with, ->(**args, &block) {
      if pending
        run, pending = pending, nil
        run.call
      end
      original.call(**args, &block)
    }) { yield }
  end

  test "a merged rename keeps a part someone corrected while it was on its way" do
    ioan = @account.field_voices.create!(name: "Ioan")
    [ @first, @second ].each { |speaker| speaker.name_as!(ioan, by: @user) }
    daniel = @account.field_voices.create!(name: "Daniel")
    charlie = @account.field_voices.create!(name: "Charlie")

    with_correction_before_locks(-> { FieldRecordingSpeaker.find(@second.id).name_as!(charlie, by: @user) }) do
      name_speaker(@first, voice_id: daniel.to_param, with: [ @second.to_param ])
    end

    assert_equal daniel, @first.reload.field_voice
    assert_equal charlie, @second.reload.field_voice, "the newer correction stands"
  end

  test "a merged unlink keeps a part someone corrected while it was on its way" do
    ioan = @account.field_voices.create!(name: "Ioan")
    [ @first, @second ].each { |speaker| speaker.name_as!(ioan, by: @user) }
    charlie = @account.field_voices.create!(name: "Charlie")

    with_correction_before_locks(-> { FieldRecordingSpeaker.find(@second.id).name_as!(charlie, by: @user) }) do
      name_speaker(@first, unname: true, with: [ @second.to_param ])
    end

    assert_nil @first.reload.field_voice
    assert_equal charlie, @second.reload.field_voice
  end

  test "a merged rename changes nothing when the card itself changed underneath it" do
    ioan = @account.field_voices.create!(name: "Ioan")
    [ @first, @second ].each { |speaker| speaker.name_as!(ioan, by: @user) }
    daniel = @account.field_voices.create!(name: "Daniel")
    charlie = @account.field_voices.create!(name: "Charlie")

    with_correction_before_locks(-> { FieldRecordingSpeaker.find(@first.id).name_as!(charlie, by: @user) }) do
      name_speaker(@first, voice_id: daniel.to_param, with: [ @second.to_param ])
    end

    assert_equal charlie, @first.reload.field_voice
    assert_equal ioan, @second.reload.field_voice
    assert_redirected_to account_field_recording_path(@account, @recording)
  end

  test "a merged rename is all or nothing" do
    ioan = @account.field_voices.create!(name: "Ioan")
    [ @first, @second ].each { |speaker| speaker.name_as!(ioan, by: @user) }
    daniel = @account.field_voices.create!(name: "Daniel")
    calls = 0
    original = FieldRecordingSpeaker.instance_method(:name_as!)
    FieldRecordingSpeaker.define_method(:name_as!) do |*args, **kw|
      calls += 1
      raise ActiveRecord::RecordInvalid, self if calls == 2

      original.bind_call(self, *args, **kw)
    end
    begin
      name_speaker(@first, voice_id: daniel.to_param, with: [ @second.to_param ])
    ensure
      FieldRecordingSpeaker.define_method(:name_as!, original)
    end

    assert_equal [ ioan, ioan ], [ @first.reload.field_voice, @second.reload.field_voice ]
  end

  test "a discard that lands first stops a later un-name" do
    @first.name_as!(@account.field_voices.create!(name: "Priya"), by: @user)
    stale = FieldRecordingSpeaker.find(@first.id) # loaded before the discard
    @recording.discard_and_settle!
    assert_raises(ActiveRecord::RecordNotFound) { stale.unname! }
    assert_equal "Priya", @first.reload.display_name
  end

  test "another account's voice can't be used" do
    theirs = accounts(:another_team).field_voices.create!(name: "Them")
    name_speaker(@first, voice_id: theirs.to_param)
    assert_response :not_found
    assert_nil @first.reload.field_voice
  end

  test "another account's recording can't be named" do
    theirs = ready_recording(account: accounts(:another_team), user: @user)
    patch account_field_recording_speaker_path(@account, theirs, theirs.speakers.first), params: { speaker: { name: "X" } }
    assert_response :not_found
  end

  def suggest!(speaker, name)
    speaker.update!(suggested_name: name, suggestion_quote: "there", suggestion_quote_ms: 2000,
      suggestion_source: "utility", suggestion_generation: speaker.decision_generation)
  end

  test "confirming a suggestion names the speaker; dismissing clears it" do
    suggest!(@second, "Priya")
    get account_field_recording_path(@account, @recording)
    shown = inertia_props["props"]["speakers"].last["suggestion"]
    assert_equal "Priya", shown["name"]
    assert_equal 0, shown["generation"]

    name_speaker(@second, confirm_suggestion: true, suggestion_generation: shown["generation"])
    @second.reload
    assert_equal "Priya", @second.display_name
    assert_equal "confirmed_suggestion", @second.naming_source
    assert_nil @second.suggested_name

    suggest!(@first, "Tomás")
    name_speaker(@first, dismiss_suggestion: true, suggestion_generation: @first.decision_generation)
    assert_nil @first.reload.suggested_name
    assert_nil @first.field_voice
  end

  test "a stale chip can't confirm or dismiss after a person decided something else" do
    suggest!(@second, "Priya")
    shown = @second.decision_generation
    @second.name_as!(@account.field_voices.create!(name: "Tomás"), by: @user)
    @second.unname! # back to Speaker 2: the old chip is still out of date

    name_speaker(@second, confirm_suggestion: true, suggestion_generation: shown)
    assert_nil @second.reload.field_voice
    name_speaker(@second, dismiss_suggestion: true, suggestion_generation: shown)
    assert_redirected_to account_field_recording_path(@account, @recording)
  end

  test "a suggestion for a known voice still asks 'same Priya?' before linking" do
    priya = @account.field_voices.create!(name: "Priya")
    suggest!(@second, "Priya")
    @second.update!(suggested_voice: priya)

    name_speaker(@second, confirm_suggestion: true, suggestion_generation: 0)
    assert_nil @second.reload.field_voice
    name_speaker(@second, confirm_suggestion: true, link_existing: true, suggestion_generation: 0)
    assert_equal priya, @second.reload.field_voice
  end

  test "the transcript page carries words, speakers and voices, and the 'you' hint once" do
    @account.field_voices.create!(name: "Tomás")
    get account_field_recording_path(@account, @recording)
    props = inertia_props["props"]

    assert_equal "field/recordings/show", inertia_props["component"]
    assert_equal 3, props["words"].size, "two words and the spacing between them"
    assert_equal [ "Speaker 1", "Speaker 2" ], props["speakers"].map { |s| s["name"] }
    assert_equal [ "Tomás" ], props["voices"].map { |v| v["name"] }
    assert_not_includes props["members_without_voice"].map { |m| m["user_id"] }, @user.id, "you are offered as 'You', not by name"
    assert props["show_you_hint"]
    assert props.dig("recording", "audio_url").present?

    post dismiss_you_hint_account_field_recordings_path(@account)
    get account_field_recording_path(@account, @recording)
    @inertia_props = nil # the helper memoises the first page
    assert_not inertia_props["props"]["show_you_hint"]
  end


  test "just noise sets a speaker aside, and undo asks for a name again" do
    @first.update_columns(suggested_name: "Priya", suggestion_generation: 0, suggested_at: Time.current)
    name_speaker(@first, ignore: true)

    assert_redirected_to account_field_recording_path(@account, @recording)
    @first.reload
    assert @first.ignored?
    assert_equal @user, @first.ignored_by
    assert_not @first.unnamed?
    assert_nil @first.suggested_name, "a suggestion shown for noise goes"
    assert_equal 1, FieldItems.recording_json(@recording.reload)[:unnamed_speakers]

    name_speaker(@first, unignore: true)
    assert_not @first.reload.ignored?
    assert @first.unnamed?
    assert_equal 2, FieldItems.recording_json(@recording.reload)[:unnamed_speakers]
  end

  test "stay anonymous sets a person aside without calling them noise, and the reason can change" do
    name_speaker(@first, ignore: true, ignore_as: "anonymous")

    assert_redirected_to account_field_recording_path(@account, @recording)
    @first.reload
    assert @first.ignored?
    assert @first.anonymous?
    assert_not @first.unnamed?
    assert_equal "Speaker 1", @first.display_name
    json = FieldItems.recording_json(@recording.reload)
    assert_equal 1, json[:unnamed_speakers]

    generation = @first.decision_generation
    name_speaker(@first, ignore: true, ignore_as: "noise")
    @first.reload
    assert @first.ignored?
    assert_not @first.anonymous?
    assert_equal "noise", @first.ignored_as
    assert_equal generation, @first.decision_generation, "changing only the reason is not a new decision"

    name_speaker(@first, ignore: true, ignore_as: "whatever")
    assert_equal "noise", @first.reload.ignored_as

    name_speaker(@first, unignore: true)
    assert_not @first.reload.ignored?
    assert_not @first.anonymous?
  end

  test "naming an ignored speaker takes the mark off; a named speaker can't be ignored" do
    @first.ignore!(by: @user)
    name_speaker(@first, name: "Priya")
    assert_not @first.reload.ignored?
    assert_nil @first.ignored_at

    name_speaker(@first, ignore: true)
    follow_redirect!
    @inertia_props = nil
    assert_equal "This speaker was named since the page loaded. Please look again.", inertia_props.dig("props", "errors", "name")
    assert_nil @first.reload.ignored_at
    assert_equal "Priya", @first.display_name
  end

end
