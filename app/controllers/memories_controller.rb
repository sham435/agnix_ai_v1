class MemoriesController < ApplicationController
  before_action :authenticate_user!

  def index
    @q = params[:q]
    @memories = if @q.present?
      Memory.search_by_text(@q, user_id: current_user.id, limit: 50)
    else
      current_user.memories.order(created_at: :desc).limit(100)
    end
  end

  def show
    @memory = current_user.memories.find(params[:id])
  end

  def destroy
    @memory = current_user.memories.find(params[:id])
    @memory.destroy
    redirect_to memories_path, notice: "Memory deleted."
  end

  def upload
    contents = Array(params[:contents]).map(&:to_s).reject(&:blank?)
    contents << params[:content].to_s if params[:content].present?

    if contents.empty? && params[:file].present?
      contents = params[:file].read.to_s.lines.map(&:strip).reject(&:blank?)
    end

    created = 0
    contents.each do |text|
      memory = current_user.memories.create!(content: text, source_type: params[:source_type].presence || "manual")
      EmbeddingService.embed_memory(memory) if memory.persisted?
      created += 1
    end

    respond_to do |format|
      format.html { redirect_to memories_path, notice: "#{created} memor#{created == 1 ? "y" : "ies"} created." }
      format.json { render json: { created: created }, status: :created }
    end
  end
end
