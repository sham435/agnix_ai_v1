class AutoFixAttempt < ApplicationRecord
  validates :issue_id, :iteration, :status, presence: true
  validates :iteration, numericality: { only_integer: true, greater_than: 0 }
end
