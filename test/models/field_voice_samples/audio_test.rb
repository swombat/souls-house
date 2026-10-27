require "test_helper"

class FieldVoiceSamples::AudioTest < ActiveSupport::TestCase

  Recording = Struct.new(:id)
  Speaker = Struct.new(:field_recording)
  Sample = Struct.new(:id, :source_digest, :source_segments)

  setup do
    FieldVoiceSamples::Audio.clear
    FieldVoiceSamples::Audio.executor = nil
    @account = accounts(:personal_account)
  end

  teardown do
    FieldVoiceSamples::Audio.executor&.shutdown
    FieldVoiceSamples::Audio.executor&.wait_for_termination(5)
    FieldVoiceSamples::Audio.executor = nil
    FieldVoiceSamples::Audio.clear
  end

  def pair(index)
    [ Speaker.new(Recording.new(index)), Sample.new(index, "digest-#{index}", [ [ 0, 1000 ] ]) ]
  end

  test "the warm queue is bounded: overflow is dropped and its play cuts at once" do
    started = Queue.new
    release = Queue.new
    cut_many = ->(recording, lists, &block) {
      if recording.id.zero?
        started << true
        release.pop
      end
      Tempfile.create([ "queued", ".wav" ]) do |file|
        file.write("RIFF#{recording.id}")
        file.flush
        block.call(lists.map { file.path })
      end
    }
    direct = ->(_recording, _segments, &block) {
      Tempfile.create([ "direct", ".wav" ]) do |file|
        file.write("RIFFdirect")
        file.flush
        block.call(file.path)
      end
    }
    FieldVoiceprints::Sample.stub(:cut_many, cut_many) do
      FieldVoiceprints::Sample.stub(:cut, direct) do
        assert_equal 1, FieldVoiceSamples::Audio.warm(@account, [ pair(0) ])
        started.pop # the one worker is busy

        queued = (1..FieldVoiceSamples::Audio::QUEUE).each_slice(FieldVoiceSamples::Audio::WARM_LIMIT).sum do |slice|
          FieldVoiceSamples::Audio.warm(@account, slice.map { |index| pair(index) })
        end
        assert_equal FieldVoiceSamples::Audio::QUEUE, queued
        overflow = FieldVoiceSamples::Audio::QUEUE + 1
        assert_equal 0, FieldVoiceSamples::Audio.warm(@account, [ pair(overflow) ]), "a full queue takes no more"

        # Dropped, not left pending: its play cuts straight away instead of waiting.
        speaker, sample = pair(overflow)
        assert_equal "RIFFdirect", Timeout.timeout(2) { FieldVoiceSamples::Audio.bytes(@account, speaker, sample) }

        release << true
        speaker, sample = pair(FieldVoiceSamples::Audio::QUEUE)
        assert_equal "RIFF#{FieldVoiceSamples::Audio::QUEUE}", Timeout.timeout(10) { FieldVoiceSamples::Audio.bytes(@account, speaker, sample) }
      end
    end
  end

end
