# Choosing and cutting the sample a print is made from (spec §9). Only turns
# where nobody else speaks within a second either side, longest first, up to
# 30 s, and at least 8 s of them. Never a fallback: if the speaker isn't heard
# alone for long enough, there is no sample. When the uploader said how many
# people speak and the transcriber found fewer, two voices may be merged into
# one speaker, so there is no sample either. These guards reduce the risk of
# a mixed sample; they don't prove one person, which is why the person hears
# the sample before anything is sent.
module FieldVoiceprints::Sample

  class Refused < StandardError; end

  module_function

  # [[start_ms, end_ms], ...] or raise Refused with a message for the page.
  def segments_for(speaker)
    recording = speaker.field_recording
    words = recording.transcript_words || []
    if recording.expected_speakers && recording.speakers.size < recording.expected_speakers
      raise Refused, "Fewer voices were found than expected, so #{speaker.display_name} may be merged with someone. " \
                     "Nothing can be remembered from this recording."
    end

    others = words.select { |word| word["k"] == "w" && word["spk"] && word["spk"] != speaker.label }
    turns = FieldRecording::Transcript.turns(words).select { |turn| turn[:spk] == speaker.label }
    clean = turns.select do |turn|
      others.none? { |word| word["e"] > turn[:s] - FieldVoiceprints::ISOLATION_MS && word["s"] < turn[:e] + FieldVoiceprints::ISOLATION_MS }
    end

    chosen = []
    total = 0
    clean.sort_by { |turn| -(turn[:e] - turn[:s]) }.each do |turn|
      break if total >= FieldVoiceprints::MAX_SAMPLE_MS

      length = [ turn[:e] - turn[:s], FieldVoiceprints::MAX_SAMPLE_MS - total ].min
      chosen << [ turn[:s], turn[:s] + length ]
      total += length
    end

    if total < FieldVoiceprints::MIN_SAMPLE_MS
      raise Refused, "There isn't enough clear speech from #{speaker.display_name} alone in this recording to remember " \
                     "their voice. It can be offered again on a later recording."
    end

    chosen.sort
  end

  def clean_ms(speaker)
    segments_for(speaker).sum { |from, to| to - from }
  rescue Refused
    0
  end

  # Cuts the segments from the recording into one mono 16 kHz WAV. Yields the
  # path; the file is gone when the block returns.
  def cut(recording, segments)
    recording.audio.blob.open do |input|
      Tempfile.create([ "voice-sample", ".wav" ]) do |output|
        filters = segments.each_with_index.map do |(from, to), index|
          "[0:a]atrim=start=#{from / 1000.0}:end=#{to / 1000.0},asetpts=PTS-STARTPTS[s#{index}]"
        end
        concat = "#{segments.each_index.map { |index| "[s#{index}]" }.join}concat=n=#{segments.size}:v=0:a=1[out]"
        _out, _err, status = Open3.capture3(
          "timeout", "120", "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", input.path,
          "-filter_complex", [ *filters, concat ].join(";"), "-map", "[out]", "-ac", "1", "-ar", "16000", output.path
        )
        raise Refused, "The sample couldn't be cut from this recording." unless status.success?

        yield output.path
      end
    end
  end

end
