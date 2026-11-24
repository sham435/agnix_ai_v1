class WorkspaceRun < ApplicationRecord
  KINDS = %w[exec test install export preview].freeze
  # A run row is a transcript for the panel, not an archive: the manager has
  # already clipped the output, and storing megabytes per step would grow the
  # database faster than the conversation it belongs to.
  MAX_STORED_BYTES = 60_000

  belongs_to :workspace

  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(created_at: :desc) }

  class << self
    def record!(workspace:, kind:, argv:, result:)
      create!(
        workspace: workspace,
        kind: kind,
        argv: Array(argv).map(&:to_s),
        ok: !!result[:ok],
        exit_code: result[:exit_code],
        timed_out: !!result[:timed_out],
        duration_ms: ((result[:duration_seconds].to_f * 1000).round if result[:duration_seconds]),
        stdout: clip(result[:stdout]),
        stderr: clip(result[:stderr]),
        stdout_bytes: result[:stdout].to_s.bytesize,
        stderr_bytes: result[:stderr].to_s.bytesize
      )
    end

    private

    def clip(text)
      text.to_s.byteslice(0, MAX_STORED_BYTES)
    end
  end
end
