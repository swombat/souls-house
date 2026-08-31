Rails.application.routes.draw do
  if Rails.env.test?
    namespace :test_support, path: "test" do
      namespace :e2e do
        post :setup, to: "/test_support/e2e#setup"
        post :conversation_fixture, to: "/test_support/e2e#conversation_fixture"
        post :append_messages, to: "/test_support/e2e#append_messages"
        post :assistant_message, to: "/test_support/e2e#assistant_message"
        post :invitation_url, to: "/test_support/e2e#invitation_url"
        post :perform_promote, to: "/test_support/e2e#perform_promote"
        post :state, to: "/test_support/e2e#state"
        post :cleanup, to: "/test_support/e2e#cleanup"
      end
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Public favicon files are served directly from /public when present.
  # These routes only run as a fallback when those files are missing.
  get "favicon.:format", to: "favicon#show", as: :favicon, defaults: { format: "ico" }
  get "favicon", to: "favicon#show", defaults: { format: "ico" }
  get "apple-touch-icon.png", to: "favicon#apple_touch_icon"

  get "login" => "sessions#new", as: :login
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  get "signup" => "registrations#new", as: :signup
  post "signup" => "registrations#create"
  get "check-email" => "registrations#check_email", as: :check_email
  get "email-confirmation" => "registrations#confirm_email", as: :email_confirmation
  get "set-password" => "registrations#set_password", as: :set_password
  patch "set-password" => "registrations#update_password"

  resources :passwords, param: :token, only: %i[new create edit update]

  resource :user, only: %i[edit update] do
    scope module: :users do
      resource :password, only: [ :edit, :update ]
      resource :avatar, only: :destroy
    end
  end

  # Legacy entry point for browser-managed external access keys.
  # The controller redirects this to the user's default account.
  get "api_keys", to: "api_keys#index", as: :api_keys

  # API Key Approvals (all actions keyed by token)
  get    "api_keys/approvals/:token", to: "api_key_approvals#show",    as: :api_key_approval
  post   "api_keys/approvals/:token", to: "api_key_approvals#create"
  delete "api_keys/approvals/:token", to: "api_key_approvals#destroy"

  # Telegram webhook (called by Telegram, no auth)
  post "telegram/webhook/:token", to: "telegram_webhooks#receive", as: :telegram_webhook

  resources :accounts, only: [ :new, :create, :show, :edit, :update ] do
    resources :members, controller: "account_members", only: [ :destroy ]
    resources :invitations, only: [ :create ] do
      member do
        post :resend
      end
    end

    resource :agent_initiation, only: :create, module: :accounts
    resource :agent_api_keys, only: [ :show, :update ], module: :accounts
    resource :costs, only: :show, module: :accounts
    resources :notices, only: [ :index, :create, :destroy ], module: :accounts
    resources :api_keys, path: "external_access", only: [ :index, :create, :destroy ]
    resources :services, only: :index, module: :accounts
    resource :personal_services, only: :show, module: :accounts
    resources :service_authorizations, only: :create
    resources :service_connections, only: [ :create, :update, :destroy ], module: :accounts

    resources :chats do
      collection do
        get :search
      end
      scope module: :chats do
        resource :archive, only: [ :create, :destroy ]
        resource :discard, only: [ :create, :destroy ]
        resource :fork, only: :create
        resource :moderation, only: :create
        resource :agent_assignment, only: :create
        resource :participant, only: :create
        resource :agent_trigger, only: :create
        resource :transcription, only: :create
      end
      resources :messages, only: [ :index, :create ]
    end

    resources :agents, except: :show do
      member do
        get :onboarding, to: "agents/onboarding#show"
        get :promote, to: "agents/promote#show"
        post "promote/github_access", to: "agents/promote#github_access", as: :github_access_promote
        post "promote/begin", to: "agents/promote#begin", as: :begin_promote
        get "promote/regenerate_credentials", to: "agents/promote#regenerate_credentials"
        post "promote/regenerate_credentials", to: "agents/promote#regenerate_credentials", as: :regenerate_credentials_promote
        post "promote/cancel", to: "agents/promote#cancel", as: :cancel_promote
        get "promote/identity_export", to: "agents/promote#identity_export", as: :identity_export
        post "promote/send_test_request", to: "agents/promote#send_test_request", as: :send_test_request
        post "promote/send_orientation", to: "agents/promote#send_orientation", as: :send_orientation
      end

      scope module: :agents do
        resource :provisioning_retry, only: :create
        resource :orientation_retry, only: :create
        resource :hosting_diagnostics, only: :show do
          get :file_preview
        end
        resource :sandbox_recreation, only: :create
        resource :refinement, only: :create
        resource :telegram_test, only: :create
        resource :telegram_webhook, only: :create
        resource :predecessor, only: :create
        resource :provider_subscription, only: [ :show, :create, :update, :destroy ] do
          post :cancel
          post :code
        end
        resource :provider_subscription_usage, only: :show
        resources :service_accesses, only: :update
        resources :memories, only: [ :create ] do
          resource :discard, only: [ :create, :destroy ], module: :memories
          resource :protection, only: [ :create, :destroy ], module: :memories
        end
      end
    end

      resources :agents, only: [ :index, :show ]
    resources :whiteboards, only: [ :index, :update ]
  end

  resources :messages, only: [ :update, :destroy ] do
    scope module: :messages do
      resource :retry, only: :create
      resource :hallucination_fix, only: :create
      resource :voice, only: :create
    end
  end

  namespace :admin do
    resources :agents, only: [] do
      resource :runtime, only: :show, controller: "agent_runtime_sessions"
    end
    resources :accounts, only: [ :index ] do
      member do
        patch :disable
        patch :enable
        patch :convert
        patch :shared_ai_credentials
      end
      resources :memberships, only: [ :create, :destroy ], controller: "account_memberships"
    end
    resources :audit_logs, only: [ :index ]
    resources :jobs, only: [ :index, :create ]
    resources :notices, only: [ :index, :create, :destroy ]
    resource :settings, only: [ :show, :update ]
  end

  # JSON API for external clients (Claude Code, etc.)
  namespace :api do
    namespace :v1 do
      resources :key_requests, only: [ :create, :show ]
      post "agents/:uuid/announce", to: "agents#announce", as: :agent_announce
      get "agents/:uuid/health", to: "agents#health", as: :agent_health
      resources :conversations, only: [ :index, :show, :create ] do
        resources :messages, only: :create do
          resources :attachments, only: :show
        end
        resource :agent_trigger, only: :create
        resources :participants, only: :create
      end
      resources :agents, only: [ :index, :show ]
      resources :telegram_conversations, only: :show
      get "telegram_conversations/:conversation_id/messages/:message_id/media",
        to: "telegram_media#show",
        as: :telegram_conversation_message_media
      get "telegram_conversations/:conversation_id/messages/:message_id/preview_frames/:id",
        to: "telegram_media#preview_frame",
        as: :telegram_conversation_message_preview_frame
      resources :telegram_messages, only: :create
      resources :telegram_subscribers, only: :index
      resources :safeguard_detections, only: :show do
        resource :reclaim, only: :create, controller: "safeguard_reclaims"
      end
      resource :attention, only: :show
      resource :subscription_usage, only: :show
      resources :service_connections, only: [] do
        resource :access_token, only: :show, controller: "service_connection_tokens"
      end
      resources :whiteboards, only: [ :index, :show, :create, :update ]
    end
  end

  get "service_authorizations/callback", to: "service_authorizations#callback", as: :service_authorization_callback

  # GitHub integration (OAuth + repo selection + settings)
  resource :github_integration, only: %i[show create update destroy], controller: "github_integration" do
    get :callback
    get :select_repo
    post :save_repo
    post :sync
  end

  # X/Twitter integration (OAuth 2.0 with PKCE)
  resource :x_integration, only: %i[show create update destroy], controller: "x_integration" do
    get :callback
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  get "privacy" => "pages#privacy", as: :privacy
  get "terms" => "pages#terms", as: :terms
  get "safeguard-responses" => "pages#safeguard_responses", as: :safeguard_responses
  get "create_flash" => "pages#create_flash"
  root "pages#home"
end
