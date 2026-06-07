# == Schema Information
#
# Table name: projects
#
#  id              :uuid             not null, primary key
#  organization_id :uuid             not null
#  user_id         :uuid             not null
#  agent_id        :uuid             not null
#  name            :string           not null
#  description     :text
#  instructions    :text
#  root_path       :string
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Project < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  belongs_to :agent

  has_many :conversations, dependent: :nullify
  has_many :project_files, dependent: :destroy
  has_many :project_links, dependent: :destroy

  validates :name, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  def instructions_for_system_prompt
    return "" unless instructions.present?
    <<~PROMPT
      ## Project Context
      Name: #{name}
      Description: #{description}
      Instructions: #{instructions}
    PROMPT
  end
end
