# Choosing and cutting a speaker's sample (spec 2026-10-19 §6). Only turns
# where nobody else speaks within a second either side, longest first, up to
# 30 s, and at least 4 s of them. Never a fallback: if the speaker isn't heard
# alone for long enough, there is no sample. When the uploader said how many
# people speak and the transcriber found fewer, two voices may be merged into
# one speaker, so there is no sample either. These guards reduce the risk of
# a mixed sample; they don't prove one person. Nobody listens before a sample
# is used: the held-out check (FieldVoiceprints::Validation) is what keeps a
# print that a bad sample pulled from guessing.
module FieldVoiceprints::Sample

  class Refused < StandardError; end

  module_function

  # [[start_ms, end_ms], ...] or raise Refused with a message for the page.
  def segments_for(speaker)
    recording = speaker.field_recording
    if recording.supplied?
      raise Refused, "This recording came with its own transcript, which has no word timings."
    end

    words = recording.transcript_words || []
    if recording.expected_speakers && recording.speakers.size < recording.expected_speakers
      raise Refused, "Fewer voices were found than expected, so #{speaker.display_name} may be merged with someone."
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
      raise Refused, "There isn't enough clear speech from #{speaker.display_name} alone in this recording."
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
    cut_many(recording, [ segments ]) { |paths| yield paths.first }
  end

  # The same cut for several segment lists from one recording, in a single
  # download and a single decode. Yields the paths, in order; the files are
  # gone when the block returns.
  def cut_many(recording, segment_lists)
    recording.audio.blob.open do |input|
      Dir.mktmpdir("voice-sample") do |dir|
        graph = []
        outputs = []
        segment_lists.each_with_index do |segments, list|
          labels = segments.each_with_index.map do |(from, to), index|
            graph << "[0:a]atrim=start=#{from / 1000.0}:end=#{to / 1000.0},asetpts=PTS-STARTPTS[s#{list}_#{index}]"
            "[s#{list}_#{index}]"
          end
          graph << "#{labels.join}concat=n=#{segments.size}:v=0:a=1[out#{list}]"
          outputs << File.join(dir, "sample-#{list}.wav")
        end
        maps = outputs.each_with_index.flat_map { |path, list| [ "-map", "[out#{list}]", "-ac", "1", "-ar", "16000", path ] }
        _out, _err, status = Open3.capture3(
          "timeout", "120", "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", input.path,
          "-filter_complex", graph.join(";"), *maps
        )
        raise Refused, "The sample couldn't be cut from this recording." unless status.success?

        yield outputs
      end
    end
  end

end
