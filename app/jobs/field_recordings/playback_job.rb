# Makes the player's copy of a recording (FieldRecording::Playback): an AAC
# .m4a the browser can seek exactly, where the original is an MP3 it can't.
# Enqueued once a recording is admitted, and again from the transcript page
# for recordings made before copies existed. Running twice does no harm: a
# copy already attached is kept, and a second copy that lands anyway replaces
# the first.
module FieldRecordings
  class PlaybackJob < ApplicationJob

    queue_as :background

    def perform(recording_id)
      recording = FieldRecording.find_by(id: recording_id)
      return unless recording&.kept? && recording.audio.attached? && !recording.playback.attached?

      recording.audio.blob.open do |input|
        next unless FieldRecording::Playback.needed?(input.path)

        Dir.mktmpdir("playback") do |dir|
          output = File.join(dir, "playback.m4a")
          next unless FieldRecording::Playback.transcode(input.path, output)

          recording.playback.attach(
            io: File.open(output),
            filename: FieldRecording::Playback.filename_for(recording.audio.blob),
            content_type: FieldRecording::Playback::CONTENT_TYPE
          )
        end
      end
    rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
      nil
    end

  end
end
