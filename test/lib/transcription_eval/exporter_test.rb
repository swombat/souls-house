require "test_helper"
require Rails.root.join("lib/transcription_eval/exporter").to_s

class TranscriptionEval::ExporterTest < ActiveSupport::TestCase

  setup do
    @speaker = users(:confirmed_user)
    @other = users(:existing_user)
    @chat = Chat.create!(account: @speaker.personal_account)
    @out = Pathname(Dir.mktmpdir("transcription-eval"))
  end

  teardown { FileUtils.rm_rf(@out) }

  test "exports the speaker's voice messages, discarded ones flagged, with prior context" do
    @chat.messages.create!(role: "assistant", content: "What should we merge?")
    kept = voice_message(@speaker, "Okay, so we can merge this.")
    deleted = voice_message(@speaker, "Okay so we came urge this")
    deleted.discard!
    @chat.messages.create!(role: "user", user: @speaker, content: "typed, no audio")
    voice_message(@other, "someone else's voice")

    count = TranscriptionEval::Exporter.new(out_dir: @out, emails: [ @speaker.email_address.upcase ]).run

    assert_equal 2, count
    rows = @out.join("manifest.jsonl").readlines.map { |l| JSON.parse(l) }
    assert_equal [ kept.to_param, deleted.to_param ], rows.map { |r| r["sample_id"] }
    assert_equal [ false, true ], rows.map { |r| r["discarded"] }
    assert_equal "Okay, so we can merge this.", rows.first["sent_text"]
    assert_equal [ "What should we merge?" ], rows.first["context"].map { |c| c["content"] }
    assert_equal "fake audio", @out.join(rows.first["audio_path"]).binread
  end

  test "refuses to run without a speaker" do
    assert_raises(ArgumentError) { TranscriptionEval::Exporter.new(out_dir: @out, emails: []) }
  end

  private

  def voice_message(user, text)
    chat = user == @speaker ? @chat : Chat.create!(account: user.personal_account)
    message = chat.messages.create!(role: "user", user: user, content: text)
    message.audio_recording.attach(io: StringIO.new("fake audio"), filename: "recording.webm", content_type: "audio/webm")
    message.update!(audio_source: true)
    message
  end

end
