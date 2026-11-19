# /computers: the address the Mac app opens when it shows a pairing code. It
# lands on the Computers page of the person's own account, with "Add a
# computer" open.
class ComputersRedirectsController < ApplicationController

  def show
    account = Current.user&.default_account
    return redirect_to root_path unless account

    redirect_to account_companion_devices_path(account, pair: 1)
  end

end
