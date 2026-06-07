class AgentsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!
  before_action :set_agent, only: [:show, :edit, :update, :destroy]

  def index
    @agents = current_organization.agents.order(created_at: :desc)
  end

  def new
    @agent = current_organization.agents.new
  end

  def create
    @agent = current_organization.agents.build(permitted_agent_params)
    @agent.slug = @agent.name.parameterize if @agent.slug.blank?

    if @agent.save
      redirect_to @agent, notice: "Agent created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @conversations = @agent.conversations.where(status: "active").order(created_at: :desc).limit(10)
    @runs = @agent.runs.order(created_at: :desc).limit(20)
  end

  def edit
  end

  def update
    if @agent.update(permitted_agent_params)
      redirect_to params[:return_to].presence || @agent, notice: "Agent updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @agent.destroy
    redirect_to agents_path, notice: "Agent deleted."
  end

  def search
    @agents = current_organization.agents
      .where("name ILIKE ? OR description ILIKE ?", "%#{params[:q]}%", "%#{params[:q]}%")
      .limit(10)
    render json: @agents
  end

  private

  def set_agent
    @agent = current_organization.agents.find(params[:id])
  end
end
