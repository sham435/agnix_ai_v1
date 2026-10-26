# frozen_string_literal: true

# Phase 5b — /explore: the ChatGPT-Explore-style catalog of curated agent
# templates. GET stays side-effect-free (cards render from the frozen
# Templates constant); POST /explore/start is the only writer, and it goes
# through Agents::InstantiateTemplate + Conversations::StartChat so the
# streaming placeholder contract is identical to the dashboard composer.
class ExploreController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!

  def index
    @categories = Agents::Templates.categories
    @templates = Agents::Templates.search(query: params[:q], category: params[:category])
    @installed_slugs = current_organization.agents.where(slug: @templates.map { |t| t[:slug] }).pluck(:slug).to_set
  end

  # "Start chat": instantiate (or reuse) the template for this organization,
  # open a conversation through the shared startup path, and land in it.
  # Optional content rides along as the first message — placeholder + job
  # semantics then match a normal composer send exactly.
  def start
    agent = Agents::InstantiateTemplate.call(slug: params[:slug], organization: current_organization)
    content = params[:content].to_s.strip.presence
    conversation = Conversations::StartChat.call(
      user: current_user,
      agent: agent,
      content: content,
      # With content, the title derives from it exactly like a composer send;
      # only a bare "Start chat" gets the agent-named default.
      title: content ? nil : "New conversation with #{agent.name}"
    )
    redirect_to conversation_path(conversation), notice: "#{agent.name} is ready."
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
