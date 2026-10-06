class FieldFilesController < ApplicationController

  require_feature_enabled :agents
  before_action :set_field_file, only: %i[update destroy]

  def create
    attributes = field_file_params
    unless FieldFile::Upload.uploaded_file?(attributes[:file])
      return redirect_to account_field_path(current_account, tab: "files"),
        inertia: { errors: { file: "Choose a file to upload." } }
    end

    field_file = current_account.field_files.new(attributes.merge(uploaded_by: Current.user))

    if field_file.save
      redirect_to account_field_path(current_account, tab: "files", item: "file-#{field_file.to_param}"),
        notice: "Brought into the Field."
    else
      redirect_to account_field_path(current_account, tab: "files"),
        inertia: { errors: { file: field_file.errors.full_messages.to_sentence } }
    end
  end

  def update
    if @field_file.update(params.require(:field_file).permit(:title, :note))
      redirect_to account_field_path(current_account, tab: "files", item: "file-#{@field_file.to_param}")
    else
      redirect_to account_field_path(current_account, tab: "files", item: "file-#{@field_file.to_param}"),
        alert: @field_file.errors.full_messages.to_sentence
    end
  end

  def destroy
    @field_file.discard!
    redirect_to account_field_path(current_account, tab: "files"), notice: "Deleted from the Field."
  end

  private

  def set_field_file
    @field_file = current_account.field_files.kept.find(params[:id])
  end

  def field_file_params
    params.require(:field_file).permit(:title, :note, :file)
  end

end
