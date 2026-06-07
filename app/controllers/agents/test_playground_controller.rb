class Agents::TestPlaygroundController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!
  before_action :set_agent

  def show
  end

  def run
    # Create a test conversation.
    conversation = current_user.conversations.create!(
      agent: @agent,
      title: "Test: #{params[:message].to_s.truncate(30)}"
    )

    runner = AgentRunner.new(
      agent: @agent,
      conversation: conversation,
      user: current_user
    )

    result = runner.run(params[:message], stream: false)

    render json: {
      content: result[:content],
      tokens: result[:tokens],
      tool_calls: result[:tool_calls],
      conversation_id: conversation.id
    }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_agent
    @agent = current_organization.agents.find(params[:agent_id])
  end
end
