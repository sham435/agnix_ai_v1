# == Schema Information
#
# Table name: project_files
#
#  id           :uuid             not null, primary key
#  project_id   :uuid             not null
#  filename     :string           not null
#  content_type :string
#  file_path    :string
#  size         :bigint           default(0)
#  content      :text
#  metadata     :jsonb            default({})
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
class ProjectFile < ApplicationRecord
  belongs_to :project

  validates :filename, presence: true
  validates :filename, uniqueness: { scope: :project_id }

  scope :ordered, -> { order(:filename) }
end
