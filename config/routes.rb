require "solid_cable"
Rails.application.routes.draw do
  # Mount Solid Cable at /cable for Action Cable.
  mount SolidCable::Engine => "/cable"

  # Root path.
  root "conversations#index"

  # Authentication.
  get    "login",  to: "sessions#new"
  post   "login",  to: "sessions#create"
  delete "logout", to: "sessions#destroy"

  # OAuth callbacks.
  get   "auth/:provider/callback", to: "oauth_callbacks#create"
  get   "auth/failure",            to: "oauth_callbacks#failure"
  match "auth/:provider",          to: "oauth_callbacks#passthrough", via: [ :get, :post ]

  # Resource routes.
  resources :users, only: [ :show, :update ]

  namespace :settings do
    get   :profile, to: "profiles#edit"
    patch :profile, to: "profiles#update"
    get   :billing, to: "billing#index"
    get   :integrations, to: "integrations#index"
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

  # Tool integrations.
  resources :tool_integrations, path: "integrations"

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
      resources :conversations, only: [ :index, :show ] do
        resources :messages, only: [ :create ]
      end
      resources :agents, only: [ :index, :show ]
      resources :runs, only: [ :show ]
    end
  end

  # Stripe billing routes.
  get "billing/checkout", to: "billing#checkout"
  get "billing/portal",   to: "billing#portal"

  # Health check.
  get "up", to: "rails/health#show", as: :rails_health_check

  # Render error pages.
  get "/404", to: "errors#not_found"
  get "/500", to: "errors#internal_server_error"

  # Serve static files.
  unless Rails.env.development?
    get "*path", to: "static#catch_all", constraints: ->(req) { !req.xhr? && req.format.html? }
  end
end
