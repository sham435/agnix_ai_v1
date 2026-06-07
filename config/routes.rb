require "solid_cable"
Rails.application.routes.draw do
  # Mount Solid Cable at /cable for Action Cable.
  mount SolidCable::Engine => "/cable"

  # Root path.
  root "conversations#index"

  # Authentication.
  get  "login",  to: "sessions#new"
  post "login",  to: "sessions#create"
  delete "logout", to: "sessions#destroy"

  # OAuth callbacks.
  get  "auth/:provider/callback", to: "oauth_callbacks#create"
  get  "auth/failure",            to: "oauth_callbacks#failure"
  get  "auth/:provider",          to: "oauth_callbacks#passthrough"

  # Resource routes.
  resources :users, only: [:show, :update]

  namespace :settings do
    get :profile, to: "profiles#edit"
    patch :profile, to: "profiles#update"
    get :billing, to: "billing#index"
    get :integrations, to: "integrations#index"
    get :api_keys, to: "api_keys#index"
  end

  resources :organizations do
    resources :memberships, only: [:index, :create, :update, :destroy], module: :organizations
    resources :agents do
      resources :conversations, only: [:index, :create], module: :agents
      resources :runs, only: [:index, :show], module: :agents
      get :test, to: "test_playground#show"
      post :test, to: "test_playground#run"
    end
  end

  resources :conversations, only: [:index, :show, :create, :update, :destroy] do
    resources :messages, only: [:create]
    post :regenerate, on: :member
    get  :regenerate, on: :member
    post :stop, on: :member
    get  :stop, on: :member
    post :interrupt, on: :member
  end

  resources :agents, except: [:index] do
    collection { get :search }
  end

  post "agent_runs/:id/resume", to: "agent_runs#resume", as: :resume_agent_run
  patch "agent_runs/:id/switch_mode", to: "agent_runs#switch_mode", as: :switch_mode_agent_run

  resources :memories, only: [:index, :show, :destroy] do
    collection { post :upload }
  end

  # Tool integrations.
  resources :tool_integrations, path: "integrations"

  # Webhooks.
  namespace :webhooks do
    post "stripe",  to: "stripe#create"
    get  "whatsapp", to: "whatsapp#verify"
    post "whatsapp", to: "whatsapp#create"
  end

  # API v1.
  namespace :api do
    namespace :v1 do
      resources :conversations, only: [:index, :show] do
        resources :messages, only: [:create]
      end
      resources :agents, only: [:index, :show]
      resources :runs, only: [:show]
    end
  end

  # Stripe billing routes.
  get  "billing/checkout",  to: "billing#checkout"
  get  "billing/portal",    to: "billing#portal"
  post "billing/webhook",   to: "webhooks/stripe#create", as: "stripe_webhook"

  # Health check.
  get "up", to: "rails/health#show", as: :rails_health_check

  # Render error pages.
  get "/404", to: "errors#not_found", via: :all
  get "/500", to: "errors#internal_server_error", via: :all

  # Serve static files.
  unless Rails.env.development?
    get "*path", to: "static#catch_all", constraints: ->(req) { !req.xhr? && req.format.html? }
  end
end
