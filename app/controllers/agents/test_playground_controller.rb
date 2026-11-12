class Agents::TestPlaygroundController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!
  before_action :set_agent

  def show
  end

  def run
    # Meter first: a turn that cannot fit today's allowance creates nothing.
    reservation = Quota.reserve(current_organization, estimate: Quota.estimate(@agent, params[:message]))

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
    Quota.settle(reservation, actual: result[:tokens])

    render json: {
      content: result[:content],
      tokens: result[:tokens],
      tool_calls: result[:tool_calls],
      conversation_id: conversation.id
    }
  rescue Quota::Exceeded => e
    render json: { error: e.message, code: e.code }, status: :too_many_requests
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_agent
    @agent = current_organization.agents.find(params[:id] || params[:agent_id])
  end
end
