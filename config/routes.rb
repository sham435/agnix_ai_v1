require "solid_cable"
Rails.application.routes.draw do
  # Mount Solid Cable at /cable for Action Cable.
  mount SolidCable::Engine => "/cable"

  # Root path.
  root "conversations#index"

  # Authentication.
  get    "login",       to: "sessions#new"
  post   "login",       to: "sessions#create"
  get    "login/otp",   to: "sessions#otp",        as: :login_otp
  post   "login/otp",   to: "sessions#verify_otp"
  delete "logout",      to: "sessions#destroy"

  # OAuth callbacks.
  get   "auth/:provider/callback", to: "oauth_callbacks#create"
  get   "auth/failure",            to: "oauth_callbacks#failure"
  match "auth/:provider",          to: "oauth_callbacks#passthrough", via: [ :get, :post ]

  # Resource routes.
  resources :users, only: [ :show, :update ]

  namespace :settings do
    get   :profile, to: "profiles#edit"
    patch :profile, to: "profiles#update"
    # Two-factor (TOTP) enrollment lives on its own page because the QR code is
    # shown exactly once, before the secret is stored.
    resource :two_factor, only: [ :show, :create, :destroy ] do
      post :confirm, on: :collection
    end
    get   :billing, to: "billing#index"
    get   :integrations, to: "integrations#index"
    # Per-organization model provider keys (Settings::IntegrationsController#save_key).
    post  :integrations_keys, to: "integrations#save_key", as: :integrations_keys
    get   :api_keys, to: "api_keys#index"
    patch :theme, to: "preferences#update_theme"
  end

  resources :organizations do
    resources :memberships, only: [ :index, :create, :update, :destroy ], module: :organizations
    resources :agents do
      resources :conversations, only: [ :index, :create ], module: :agents
      resources :runs, only: [ :index, :show ], module: :agents
      member do
        get  :test, to: "agents/test_playground#show"
        post :test, to: "agents/test_playground#run"
      end
    end
  end

  resources :conversations, only: [ :index, :show, :create, :update, :destroy ] do
    collection { get :search }
    resources :messages, only: [ :create ]
    member do
      match :regenerate, via: [ :get, :post ]
      match :stop,       via: [ :get, :post ]
      post  :interrupt
    end
  end

  resources :agents, except: [ :index ] do
    collection { get :search }
  end

  resources :agent_runs, only: [] do
    member do
      post  :resume
      patch :switch_mode
    end
  end

  resources :memories, only: [ :index, :show, :destroy ] do
    collection { post :upload }
  end

  # Phase 2 — Scheduled Tasks (ChatGPT Automations). Additive; registered well
  # above the catch-all so the *path route never shadows /scheduled in test/prod.
  resources :scheduled_tasks, path: "scheduled", only: [ :index, :new, :create, :edit, :update, :destroy ] do
    member do
      post :pause
      post :resume
    end
  end

  # Phase 3 — Image Generation gallery (/images). Additive, and — same rule as
  # /scheduled — registered well above the catch-all so /images is never
  # shadowed. show renders inside the top-level "modal" turbo frame.
  resources :images, only: [ :index, :show, :create, :destroy ] do
    member do
      post :regenerate
      get  :download
    end
  end

  # Phase 5 — Explore Agents catalog (/explore). Additive, above the
  # catch-all like /scheduled and /images. GET index is read-only; POST start
  # instantiates a template inside the current org and opens a conversation.
  get "explore", to: "explore#index", as: :explore
  post "explore/start", to: "explore#start", as: :explore_start

  # Tool integrations. Phase 4 (Plugins Manager) adds the marketplace routes
  # additively: the custom collection paths (connect/<key>, plugin/<key>) are
  # matched before member show, and catalog keys are never uuid-shaped, so
  # /integrations/:id keeps resolving exactly as before. toggle flips
  # is_active without leaving the grid.
  resources :tool_integrations, path: "integrations" do
    collection do
      get "connect/:key", action: :connect, as: :connect
      get "plugin/:key", action: :plugin, as: :plugin
    end
    member do
      post :toggle
    end
  end

  # Webhooks.
  namespace :webhooks do
    post "stripe",   to: "stripe#create"
    get  "whatsapp", to: "whatsapp#verify"
    post "whatsapp", to: "whatsapp#create"
  end
  post "billing/webhook", to: "webhooks/stripe#create", as: :stripe_webhook

  # API v1.
  namespace :api do
    namespace :v1, defaults: { format: :json } do
      get    "csrf",         to: "csrf#show"
      post   "sessions",     to: "sessions#create"
      delete "sessions",     to: "sessions#destroy"
      get    "capabilities", to: "capabilities#index"
      get    "library",      to: "assets#library"
      resources :assets, only: [ :create, :show, :destroy ] do
        member do
          get  :download
          get  :preview
          post :add_to_library
        end
      end
      resources :attachment_drafts, only: [ :index, :create, :destroy ]
      resources :conversations, only: [ :index, :show, :create ] do
        resources :messages, only: [ :create ]
      end
      resources :agents, only: [ :index, :show ]
      resources :runs, only: [ :show ]

      # OpenAI-compatible gateway for OpenCode
      namespace :openai do
        get "models", to: "chat_completions#models"
        post "chat/completions", to: "chat_completions#create"
      end
    end
  end

  # Stripe billing routes.
  get "billing/checkout", to: "billing#checkout"
  get "billing/portal",   to: "billing#portal"

  # Health check.
  get "up", to: "rails/health#show", as: :rails_health_check

  # The agent process table — `ps` for runs. Drawn only on a local box: on
  # production the route simply does not exist, and the controller guards
  # again with Rails.env.local? so nothing here is reachable from outside.
  # Placed above the static catch-all so that route can never swallow it.
  if Rails.env.local?
    get "dev/processes", to: "dev/processes#index", as: :dev_processes
  end

  # Render error pages.
  get "/404", to: "errors#not_found"
  get "/500", to: "errors#internal_server_error"

  # Serve static files.
  unless Rails.env.development?
    get "*path", to: "static#catch_all", constraints: ->(req) { !req.xhr? && req.format.html? }
  end
end
