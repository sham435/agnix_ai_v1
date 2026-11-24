class Api::V1::MessagesController < ApplicationController
  before_action :authenticate_user!

  def create
    @conversation = current_user.conversations.find(params[:conversation_id])
    admission = Conversations::TurnAdmission.call(
      conversation: @conversation,
      user: current_user,
      params: message_params,
      requested_mode: message_params[:admission]
    )

    return render json: { errors: admission.errors }, status: :unprocessable_entity if admission.status == :invalid

    render json: {
      message: admission.message,
      status: admission.status == :started ? :processing : admission.status,
      admission: admission.status,
      request_id: admission.request_id,
      background_task_count: Conversations::TurnAdmission.task_summary(@conversation)[:active],
      queued_count: admission.queued_count
    }, status: (admission.message ? :created : :accepted)
  rescue Llm::ModelCatalogue::Error => e
    render json: { error_code: e.code, error: e.message }, status: :unprocessable_entity
  end

  private

  def message_params
    params.permit(:content, :attachment_draft_token, :client_request_id, :admission,
                  attachment_asset_ids: [], tools: [])
  end
end
