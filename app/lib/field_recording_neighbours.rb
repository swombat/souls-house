# The recordings either side of one, for the transcript page's previous and
# next buttons. "Next" is the one below it in the Field's Recordings tab, which
# lists newest first (FieldListing): so next is older, previous is newer. Ties
# on the date fall back to the id, the same as the list.
#
# The waiting pair skips to the nearest recording with a speaker still to
# name, by FieldListing::WAITING_RECORDINGS: the same rule as the Waiting tab,
# so the yellow buttons and the tab can't disagree about what is waiting.
class FieldRecordingNeighbours

  SORT = "COALESCE(field_recordings.recorded_at, field_recordings.created_at)".freeze

  def initialize(recording)
    @recording = recording
  end

  def as_json(*)
    {
      previous: link(newer(scope)),
      next: link(older(scope)),
      previous_waiting: link(newer(scope.where(FieldListing::WAITING_RECORDINGS))),
      next_waiting: link(older(scope.where(FieldListing::WAITING_RECORDINGS)))
    }
  end

  private

  def scope
    @recording.account.field_recordings.kept.where.not(id: @recording.id)
  end

  def sort_at
    @sort_at ||= @recording.recorded_at || @recording.created_at
  end

  def older(scope)
    scope.where("(#{SORT}, field_recordings.id) < (?, ?)", sort_at, @recording.id)
      .order(Arel.sql("#{SORT} DESC, field_recordings.id DESC")).first
  end

  def newer(scope)
    scope.where("(#{SORT}, field_recordings.id) > (?, ?)", sort_at, @recording.id)
      .order(Arel.sql("#{SORT} ASC, field_recordings.id ASC")).first
  end

  def link(recording)
    return nil unless recording

    { id: recording.to_param, title: recording.title,
      url: Rails.application.routes.url_helpers.account_field_recording_path(recording.account, recording) }
  end

end
