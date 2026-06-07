# ViewComponent configuration
Rails.application.config.view_component.preview_paths << Rails.root.join("spec/components").to_s
Rails.application.config.view_component.preview_route = "/view_components"
Rails.application.config.view_component.preview_controller = "ViewComponentsPreviewsController"
