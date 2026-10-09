# The account's transcription glossary page. Any confirmed member may add,
# pin and remove terms: it's the account's shared vocabulary, like its rooms.
class Accounts::TranscriptionGlossariesController < ApplicationController

  include TranscriptionGlossaryActions

  before_action :set_account

  def show
    render inertia: "accounts/transcription_glossary", props: {
      account: @account,
      path: account_transcription_glossary_path(@account),
      **glossary_payload(@account)
    }
  end

  def create
    term = TranscriptionGlossary.new(@account).add!(glossary_term_param.to_s, by: Current.user, pinned: glossary_pinned_param || false)
    audit("add_transcription_glossary_term", term, term: term.term)
    redirect_to account_transcription_glossary_path(@account), notice: "Added \"#{term.term}\""
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_transcription_glossary_path(@account), inertia: { errors: e.record.errors.to_hash }
  end

  def update
    term = pin_glossary_term!(@account, glossary_term_param.to_s, pinned: glossary_pinned_param || false, by: Current.user)
    audit("pin_transcription_glossary_term", term, term: term.term, pinned: term.pinned)
    redirect_to account_transcription_glossary_path(@account)
  end

  def destroy
    term = TranscriptionGlossary.new(@account).remove!(glossary_term_param.to_s, by: Current.user)
    audit("remove_transcription_glossary_term", term, term: term.term)
    redirect_to account_transcription_glossary_path(@account), notice: "Removed \"#{term.term}\". It won't be added back automatically."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_transcription_glossary_path(@account), inertia: { errors: e.record.errors.to_hash }
  end

  private

  def set_account
    @account = find_current_user_account!(params[:account_id])
  end

  def current_account
    @account || super
  end

end
