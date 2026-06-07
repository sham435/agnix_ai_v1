class Agents::CardComponent < ViewComponent::Base
  def initialize(agent:, show_actions: true)
    @agent = agent
    @show_actions = show_actions
  end

  private

  attr_reader :agent, :show_actions
end
