module FieldVoiceSamples
  module Review

    module_function

    def review!(sample, digest:, by:, included:, unconfirmed_only: false)
      raise Invalid, "Choose whether to include this sample." unless [ true, false ].include?(included)
      Uploads.with_sample_lock(sample) do |live|
        check!(live, digest, current: included)
        unconfirmed!(live) if unconfirmed_only
        if included
          raise Invalid, "A person must confirm this sample." unless Uploads.human?(by) || live.manually_confirmed?
          raise Conflict, "Wait for this sample to finish learning." unless live.embedding.present? && live.profile.present?
          raise Conflict, "Learning is off for this voice." unless live.field_voice.kept? && live.field_voice.remember?
          raise Conflict, "The retained audio changed. Upload it again." unless
            Digest::SHA256.hexdigest(live.audio.download) == live.content_sha256
          FieldVoiceprints::Limits.active!(live.field_voice, except: live)
          live.assign_attributes(confirmed_digest: digest, confirmed_by: by, confirmed_at: Time.current) if Uploads.human?(by)
        end
        live.update!(eligible: included, excluded: !included, review_generation: live.review_generation + 1)
        FieldVoiceprints::Learning.rebuild!(live.field_voice)
        live
      end
    end

    def reattribute!(sample, voice:, digest:, by:, unconfirmed_only: false)
      sample.account.with_lock do
        live = FieldVoiceSample.find_by!(id: sample.id)
        raise Invalid, "Choose a voice in this account." unless voice.account_id == live.account_id

        live.field_recording&.lock!
        voices = FieldVoice.where(id: [ live.field_voice_id, voice.id ]).order(:id).lock.to_a
        live.reload
        check!(live, digest)
        unconfirmed!(live) if unconfirmed_only
        target = voices.find { |row| row.id == voice.id }
        raise Conflict, "This voice is no longer available." unless target&.kept?
        next live if live.field_voice_id == target.id

        Uploads.ensure_pending_capacity!(target)
        previous = voices.find { |row| row.id == live.field_voice_id }
        live.assign_attributes(field_voice: target, eligible: false, excluded: false, confirmed_digest: nil,
          rollback_embedding: nil, rollback_profile: nil,
          confirmed_by: nil, confirmed_at: nil, review_generation: live.review_generation + 1,
          learning_status: live.embedding.present? ? "learned" : "pending",
          label_origin: Uploads.human?(by) ? "human" : "machine")
        live.source_digest = Uploads.source_digest(live)
        live.save!
        [ previous, target ].each { |row| FieldVoiceprints::Learning.rebuild!(row) }
        live
      end
    end

    def remove!(sample, digest:, by:, unconfirmed_only: false)
      Uploads.with_sample_lock(sample) do |live|
        check!(live, digest, current: false)
        unconfirmed!(live) if unconfirmed_only
        live.update!(removed_at: Time.current, eligible: false, confirmed_digest: nil,
          rollback_embedding: nil, rollback_profile: nil,
          confirmed_by: nil, confirmed_at: nil, review_generation: live.review_generation + 1)
        FieldVoiceprints::Learning.rebuild!(live.field_voice)
        live
      end
    end

    # Checked under the sample lock, so a confirmation that lands between a
    # resident's read and its write still wins.
    def unconfirmed!(sample)
      raise Forbidden, "A person has confirmed this sample. Only a person can change it." if sample.ever_confirmed?
    end

    def check!(sample, digest, current: true)
      raise Invalid, "This operation requires an uploaded sample." unless sample.standalone?
      raise Conflict, "This sample changed. Reload and retry." unless digest.present? &&
        sample.removed_at.nil? && sample.source_digest == digest && (!current || sample.source_current?)
    end

  end
end
