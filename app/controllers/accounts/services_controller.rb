class Accounts::ServicesController < ApplicationController

  def index
    redirect_to account_integrations_path(current_account, connect: params[:connect].presence)
  end

end
