module FieldVoiceSamples
  # The review player's audio: each sample's exact montage, cut from its
  # source recording and held only in this process's memory (never the Rails
  # cache, which production keeps in the cache database, and never on disk).
  #
  # A cut is slow when the source is long: a 3.6-hour MP3 took 5.8 s to
  # download and 7.8 s to decode up to a clip near its end, and every sample
  # paid both. So the page asks for the next few samples ahead of play
  # (`warm`), and one background pass per recording downloads it once and
  # cuts all of them in a single decode. A play that arrives while its cut is
  # being made waits for that cut instead of starting another.
  module Audio

    CACHE = ActiveSupport::Cache::MemoryStore.new(size: 64.megabytes, expires_in: 10.minutes)
    WAIT = 150.seconds
    WARM_LIMIT = 8
    QUEUE = 32

    @lock = Mutex.new
    @pending = {}

    class << self

      # Samples are cut in the background by default; tests swap in
      # Concurrent::ImmediateExecutor.
      attr_writer :executor

      # One worker, at most QUEUE recordings waiting; more are dropped and
      # cut on play instead. (SingleThreadExecutor ignores max_queue, so a
      # one-thread pool it is: Mira's review of #610.)
      def executor
        @executor ||= Concurrent::ThreadPoolExecutor.new(
          min_threads: 0, max_threads: 1, max_queue: QUEUE, fallback_policy: :discard
        )
      end

      def key(account, sample)
        [ "field-voice-sample-audio-v1", account.id, sample.id, sample.source_digest ]
      end

      # The montage's WAV bytes: cached, or the cut already under way, or a
      # fresh cut. Raises FieldVoiceprints::Sample::Refused if it can't be cut.
      def bytes(account, speaker, sample)
        key = key(account, sample)
        CACHE.cleanup
        cached = CACHE.read(key)
        return cached if cached

        future = @lock.synchronize { @pending[key] }
        # A background cut that failed or ran long: cut it here instead.
        value = future&.value(WAIT)
        return value if value

        bytes = FieldVoiceprints::Sample.cut(speaker.field_recording, sample.source_segments) { |path| File.binread(path) }
        CACHE.write(key, bytes)
        bytes
      end

      # Starts cutting these [speaker, sample] pairs in the background, one
      # pass per source recording. Pairs already cut or under way are skipped.
      # Returns how many were queued.
      def warm(account, pairs)
        claimed = @lock.synchronize do
          pairs.first(WARM_LIMIT).filter_map do |speaker, sample|
            key = key(account, sample)
            next if @pending.key?(key) || CACHE.exist?(key)

            @pending[key] = Concurrent::Promises.resolvable_future
            [ key, speaker.field_recording, sample.source_segments ]
          end
        end
        claimed.group_by { |_key, recording, _segments| recording.id }.sum do |_recording_id, jobs|
          next jobs.size if executor.post { cut_all(jobs.first[1], jobs) }

          release(jobs, StandardError.new("The sample queue is full."))
          0
        end
      end

      def clear
        CACHE.clear
        @lock.synchronize { @pending.clear }
      end

      private

      def cut_all(recording, jobs)
        Rails.application.executor.wrap do
          FieldVoiceprints::Sample.cut_many(recording, jobs.map(&:last)) do |paths|
            jobs.zip(paths).each do |(key, _recording, _segments), path|
              bytes = File.binread(path)
              CACHE.write(key, bytes)
              future = @lock.synchronize { @pending.delete(key) }
              future&.fulfill(bytes, false)
            end
          end
        end
      rescue StandardError => error
        release(jobs, error)
      end

      def release(jobs, error)
        jobs.each do |key, _recording, _segments|
          future = @lock.synchronize { @pending.delete(key) }
          future&.reject(error, false)
        end
      end

    end

  end
end
