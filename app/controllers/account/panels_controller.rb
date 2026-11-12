class Account::PanelsController < ApplicationController
  include AccountPanelResponses

  before_action :authenticate_user!

  # The panel is a turbo frame, so the frame request gets the frame document
  # and a direct visit to /account gets the same section as a page.
  def show
    prepare_panel(section: params[:section])

    if turbo_frame_request?
      render "account/panels/show", layout: false
    else
      render "account/panels/page"
    end
  end
end
