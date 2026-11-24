require "solid_cable"
Rails.application.routes.draw do
  # Mount Solid Cable at /cable for Action Cable.
  mount SolidCable::Engine => "/cable"

  # Root path.
  root "conversations#index"
  get "dashboard", to: "conversations#index", as: :dashboard

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
    post  :integrations_connection, to: "integrations#connection", as: :integrations_connection
    post  :integrations_model, to: "integrations#model", as: :integrations_model
    post  :integrations_default_model, to: "integrations#default_model", as: :integrations_default_model
    post  :integrations_refresh, to: "integrations#refresh", as: :integrations_refresh
    post  :integrations_custom, to: "integrations#save_custom", as: :integrations_custom
    post  :integrations_manual_model, to: "integrations#save_model", as: :integrations_manual_model
    post  :integrations_verify_model, to: "integrations#verify_model", as: :integrations_verify_model
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
      get :tasks
      post :regenerate
      post :stop
      post  :interrupt
    end
  end

  resources :agents do
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

  get "github/approval", to: "github_approvals#show", as: :github_approval
  post "github/approval", to: "github_approvals#create"

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

  # Account & security panel: one right-side surface for profile, two-factor,
  # backup codes, phone verification, signed-in devices and quota. Every route
  # answers the panel's turbo frame in place, and each one still behaves as a
  # normal page for clients that do not run JavaScript.
  namespace :account, path: "account" do
    get    "", to: "panels#show", as: :panel

    post   "two_factor",                to: "two_factors#create",     as: :two_factor
    delete "two_factor",                to: "two_factors#disable",    as: :disable_two_factor
    post   "two_factor/confirm",        to: "two_factors#confirm",    as: :confirm_two_factor
    post   "two_factor/recovery_codes", to: "two_factors#regenerate", as: :recovery_codes

    post   "phone",                     to: "phones#request_code",    as: :phone
    post   "phone/confirm",             to: "phones#confirm",         as: :confirm_phone

    delete "devices/:id",               to: "devices#destroy",        as: :device
    delete "devices",                   to: "devices#close_everywhere", as: :devices
  end

  # Sandboxed Docker workspaces. Every route is keyed by a workspace id and a
  # path relative to /workspace; none of them accepts a host path.
  get    "workspaces",                     to: "workspaces#index",        as: :workspaces
  # Above `workspaces/:id`, or "panel" would be read as a workspace uuid.
  get    "workspaces/panel",               to: "workspaces#panel",        as: :workspace_panel
  get    "workspaces/:id",                 to: "workspaces#show",         as: :workspace
  get    "workspaces/:id/files",           to: "workspaces#files",        as: :workspace_files
  get    "workspaces/:id/file",            to: "workspaces#file",         as: :workspace_file
  get    "workspaces/:id/logs",            to: "workspaces#logs",         as: :workspace_logs
  get    "workspaces/:id/runs",            to: "workspaces#runs",         as: :workspace_runs
  post   "workspaces/:id/exec",            to: "workspaces#exec",         as: :workspace_exec
  post   "workspaces/:id/tests",           to: "workspaces#tests",        as: :workspace_tests
  post   "workspaces/:id/preview",         to: "workspaces#start_preview", as: :workspace_preview_start
  delete "workspaces/:id/preview",         to: "workspaces#stop_preview", as: :workspace_preview_stop
  get    "workspaces/:id/export",          to: "workspaces#export",       as: :workspace_export
  delete "workspaces/:id",                 to: "workspaces#destroy",      as: :workspace_destroy

  # The authenticated preview gateway. A workspace never publishes a port and
  # nothing here takes a destination: the id must belong to the signed-in user,
  # the ?session= token must still be live, and the port must be the one that
  # preview actually opened. format: false because the forwarded path belongs to
  # the sandboxed app — /static/app.css is a file, not a request for css.
  preview_via = %i[get head post put patch delete]
  match "workspaces/:id/preview/:port/*path", to: "workspace_previews#proxy",
        via: preview_via, as: :workspace_preview, constraints: { port: /\d+/ }, format: false
  match "workspaces/:id/preview/:port", to: "workspace_previews#proxy",
        via: preview_via, constraints: { port: /\d+/ }, format: false

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
      namespace :owner do
        get "tunnel", to: "tunnels#show"
        post "tunnel/refresh", to: "tunnels#refresh"
      end
      get    "csrf",         to: "csrf#show"
      post   "sessions",     to: "sessions#create"
      delete "sessions",     to: "sessions#destroy"
      get    "capabilities", to: "capabilities#index"
      get "models", to: "models#index"
      get "models/providers", to: "models#providers"
      post "models/refresh", to: "models#refresh"
      patch "models/selection", to: "models#update"
      patch "models/providers/:provider_id", to: "models#configure"
      get "models/:id/status", to: "models#status", constraints: { id: /[^\/]+/ }
      patch "conversations/:conversation_id/model", to: "models#update"
      get "library",      to: "assets#library"
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

      # The account & security panel as data, for clients that draw their own
      # screens. Same services, same session, same refusals as the browser
      # panel — and the only key any response carries is a pending enrollment
      # the client has not proved yet.
      get    "security",                   to: "security#show"
      post   "security/two_factor",        to: "two_factor#create"
      delete "security/two_factor",        to: "two_factor#destroy"
      post   "security/two_factor/confirm", to: "two_factor#confirm"
      post   "security/recovery_codes",    to: "recovery_codes#create"
      post   "security/phone",             to: "phone#create"
      post   "security/phone/confirm",     to: "phone#confirm"
      delete "security/devices/:id",       to: "devices#destroy",     as: :security_device
      delete "security/devices",           to: "devices#destroy_all", as: :security_devices

      # The Coding Workspace as data, for the mobile screen: the same provider,
      # the same ownership rules, the same argv rules and the same refusal words
      # as the web panel. Nothing here takes a host path or a container name.
      get    "workspaces",              to: "workspaces#index",          as: :workspaces
      get    "workspaces/:id",          to: "workspaces#show",           as: :workspace
      get    "workspaces/:id/file",     to: "workspaces#file",           as: :workspace_file
      get    "workspaces/:id/runs",     to: "workspaces#runs",           as: :workspace_runs
      post   "workspaces/:id/exec",     to: "workspaces#exec",           as: :workspace_exec
      post   "workspaces/:id/tests",    to: "workspaces#tests",          as: :workspace_tests
      post   "workspaces/:id/preview",  to: "workspaces#start_preview",  as: :workspace_preview_start
      delete "workspaces/:id/preview",  to: "workspaces#stop_preview",   as: :workspace_preview_stop
      delete "workspaces/:id",          to: "workspaces#destroy",        as: :workspace_stop

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
