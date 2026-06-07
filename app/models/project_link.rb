# == Schema Information
#
# Table name: project_links
#
#  id          :uuid             not null, primary key
#  project_id  :uuid             not null
#  url         :string           not null
#  title       :string
#  description :text
#  metadata    :jsonb            default({})
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class ProjectLink < ApplicationRecord
  belongs_to :project

  validates :url, presence: true

  scope :ordered, -> { order(:title) }
end
