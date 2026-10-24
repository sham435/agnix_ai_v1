# frozen_string_literal: true

# Canonical uploaded-asset metadata row.
# Bytes live in Active Storage (private Disk service) — this row is the single
# addressable descriptor used by message attachments, the Library, and
# extractions. Library items and message-attachments always reference an
# Asset; selecting a Library file never re-uploads bytes.
class Asset < ApplicationRecord
  STATUS_VALUES = %w[pending ready failed].freeze

  belongs_to :user
  belongs_to :project, optional: true

  has_one_attached :file

  has_many :message_attachments, dependent: :delete_all
  has_many :messages, through: :message_attachments
  has_many :library_items, dependent: :delete_all
  has_one :extraction, class_name: "AssetExtraction", dependent: :delete

  validates :filename, presence: true, length: { maximum: 255 }
  validates :content_type, presence: true
  validates :byte_size, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :checksum, presence: true
  validates :status, inclusion: { in: STATUS_VALUES }
  validates :metadata, presence: true
  # Duplicate ingest by the same user resolves to the existing asset instead
  # of storing bytes twice.
  validates :checksum, uniqueness: { scope: :user_id }

  scope :ready, -> { where(status: "ready") }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def image?
    metadata["category"] == "image"
  end

  # metadata["category"] set by Assets::Validator. Used to pick chips/icons.
  def category
    metadata["category"]
  end

  def public_download_name
    filename
  end

  # Downloads are authorized for the owner, or for the owner of the project
  # the asset was uploaded into. Nothing else.
  def readable_by?(user)
    user.present? && (user.id == user_id || (project && user.id == project.user_id))
  end
end
