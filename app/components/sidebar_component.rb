class SidebarComponent < ViewComponent::Base
  def initialize(user:, conversations: [], agents: [])
    @user = user
    @conversations = conversations
    @agents = agents
  end

  private

  attr_reader :user, :conversations, :agents
end
