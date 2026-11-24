class MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation

  def create
    @admission = Conversations::TurnAdmission.call(
      conversation: @conversation,
      user: current_user,
      params: message_params,
      requested_mode: message_params[:admission]
    )
    @message = @admission.message || @conversation.messages.build(role: "user", content: message_params[:content])

    if @admission.status == :invalid
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append("messages-list",
            html: admission_error(@admission.errors)), status: :unprocessable_entity
        end
        format.json { render json: { errors: @admission.errors }, status: :unprocessable_entity }
      end
      return
    end

    @background_tasks = Conversations::TurnAdmission.task_summary(@conversation)

    respond_to do |format|
      format.turbo_stream { render "messages/create" }
      format.html do
        redirect_to conversation_path(@conversation),
          notice: admission_notice
      end
      format.json do
        payload = if @admission.message
          @admission.message.as_json
        else
          { id: @admission.request_id, content: message_params[:content] }
        end
        render json: payload.merge(
          admission: @admission.status,
          request_id: @admission.request_id,
          background_task_count: @background_tasks[:active],
          queued_count: @admission.queued_count
        ), status: (@admission.message ? :created : :accepted)
      end
    end
  end

  rescue_from Llm::ModelCatalogue::Error do |error|
    render json: { error_code: error.code, error: error.message }, status: :unprocessable_entity
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  end

  def message_params
    params.require(:message).permit(
      :content, :attachment_draft_token, :client_request_id, :admission,
      attachment_asset_ids: [], tools: []
    )
  end

  def admission_notice
    case @admission.status
    when :queued then "Message queued for the next turn."
    when :steering then "Message will steer the active run at its next safe step."
    when :duplicate, :duplicate_pending then "This message was already accepted."
    else "Message sent."
    end
  end

  def admission_error(errors)
    message = ERB::Util.html_escape(Array(errors).join(" "))
    %(<div data-submission-error role="alert" class="rounded-lg border border-red-500/20 bg-red-500/5 px-3.5 py-2 text-[13px] text-red-600 dark:text-red-400">#{message} Your draft is preserved.</div>)
  end
end
