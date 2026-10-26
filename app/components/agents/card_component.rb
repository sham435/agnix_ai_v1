# frozen_string_literal: true

# Shared agent card. The original Open/Edit mode serves the org agents index;
# Phase 5 adds an Explore mode: pass start_path (+ customize_path / icon /
# installed) and the card becomes a template launcher. Defaults preserve the
# pre-Phase-5 rendering.
class Agents::CardComponent < ViewComponent::Base
  ICON_PATHS = {
    "agent"    => '<circle cx="12" cy="12" r="3"/><path d="M12 1v4M12 19v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83"/>',
    "search"   => '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    "code"     => '<path d="m8 8-4 4 4 4M16 8l4 4-4 4M13 6l-2 12"/>',
    "language" => '<path d="M4 5h7M9 3v2c0 4-2 7-5 8m2-4c1 2 3 4 6 5"/><path d="m14 17 4-9 4 9M15.5 14h5"/>',
    "mail"     => '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
    "chart"    => '<path d="M3 3v18h18"/><path d="M8 17V9m5 8V5m5 12v-7"/>',
    "image"    => '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-5-5L5 21"/>',
    "calendar" => '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M8 2v4M16 2v4M3 10h18"/>',
    "notes"    => '<path d="M4 4h16v12l-4 4H4z"/><path d="M8 8h8M8 12h6"/>'
  }.freeze

  def initialize(agent:, show_actions: true, start_path: nil, customize_path: nil, icon: nil, installed: false)
    @agent = agent
    @show_actions = show_actions
    @start_path = start_path
    @customize_path = customize_path
    @icon = icon
    @installed = installed
  end

  private

  attr_reader :agent, :show_actions, :start_path, :customize_path

  def icon_path
    ICON_PATHS.fetch(@icon.to_s, ICON_PATHS["agent"])
  end

  def installed?
    @installed
  end

  def explore_mode?
    start_path.present?
  end
end
