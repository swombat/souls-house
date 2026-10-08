# Renaming a voice: the explicit act that changes the name everywhere it
# appears (spec §7). The Voices page itself arrives with recognition (C).
class FieldVoicesController < ApplicationController

  require_feature_enabled :agents

  def update
    voice = current_account.field_voices.kept.find_by!(id: FieldVoice.decode_id(params[:id]))
    if voice.update(params.require(:field_voice).permit(:name))
      redirect_back_or_to account_field_path(current_account, tab: "recordings")
    else
      redirect_back_or_to account_field_path(current_account, tab: "recordings"),
        inertia: { errors: { name: voice.errors.full_messages.to_sentence } }
    end
  end

end
