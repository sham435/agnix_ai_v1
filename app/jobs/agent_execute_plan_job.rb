class AgentExecutePlanJob < ApplicationJob
  queue_as :agents

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return if agent_run.status != "planning"

    conversation = agent_run.conversation
    runner = AgentRunner.new(
      agent: conversation.agent,
      conversation: conversation,
      user: conversation.user
    )
    runner.resume_plan(agent_run)
  end
end
