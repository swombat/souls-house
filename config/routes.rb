Rails.application.routes.draw do
  resources :stones, only: :show do
    get "revisions/:number", to: "stones#show", as: :revision
    get "revisions/:number/content", to: "stones#content", as: :revision_content
  end
  if Rails.env.test?
    namespace :test_support, path: "test" do
      namespace :e2e do
        post :setup, to: "/test_support/e2e#setup"
        post :conversation_fixture, to: "/test_support/e2e#conversation_fixture"
        post :append_messages, to: "/test_support/e2e#append_messages"
        post :assistant_message, to: "/test_support/e2e#assistant_message"
        post :runtime_activity, to: "/test_support/e2e#runtime_activity"
        post :invitation_url, to: "/test_support/e2e#invitation_url"
        post :state, to: "/test_support/e2e#state"
        post :cleanup, to: "/test_support/e2e#cleanup"
        post :stone_fixture, to: "/test_support/e2e#stone_fixture"
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
  # Personal recovery controls remain reachable after account membership ends.
  resources :device_streams, only: [ :index, :show, :destroy ] do
    member do
      delete :revoke
      delete :erase_session
    end
  end

  # API Key Approvals (all actions keyed by token)
  get    "api_keys/approvals/:token", to: "api_key_approvals#show",    as: :api_key_approval
  post   "api_keys/approvals/:token", to: "api_key_approvals#create"
  delete "api_keys/approvals/:token", to: "api_key_approvals#destroy"

  # Telegram webhook (called by Telegram, no auth)
  post "telegram/webhook/:token", to: "telegram_webhooks#receive", as: :telegram_webhook

  resources :accounts, only: [ :new, :create, :show, :edit, :update ] do
    resources :rhythms do
      get :preview, on: :collection
      member do
        post :pause
        post :resume
        post :start
      end
    end
    resources :device_streams, only: [ :index, :create, :show, :update, :destroy ] do
      member do
        post :credential
        delete :revoke
        delete :erase_session
      end
    end
    resources :members, controller: "account_members", only: [ :destroy ]
    resources :invitations, only: [ :create ] do
      member do
        post :resend
      end
    end

    resource :agent_api_keys, only: [ :show, :update ], module: :accounts
    resources :guest_memberships, only: [ :create, :destroy ], module: :accounts
    resource :costs, only: :show, module: :accounts
    resources :notices, only: [ :index, :create, :destroy ], module: :accounts
    resources :api_keys, path: "external_access", only: [ :index, :create, :destroy ]
    resources :services, only: :index, module: :accounts
    resource :personal_services, only: :show, module: :accounts
    resource :integrations, only: :show, module: :accounts
    resource :interface, only: :show, module: :accounts
    resources :visual_tags, only: [ :create, :update, :destroy ], module: :accounts
    resources :service_authorizations, only: :create
    resources :service_connections, only: [ :create, :update, :destroy ], module: :accounts

    resources :chats do
      get :activity, on: :member
      collection do
        get :search
        post :transcription, to: "chats/transcriptions#create"
      end
      scope module: :chats do
        resource :visual_tag, only: :update
        resource :reply_dismissal, only: :create
        resource :draft, only: [ :show, :update ]
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

    get "agents", as: nil, to: redirect { |params, request| "/accounts/#{params[:account_id]}/residents#{request.query_string.present? ? "?#{request.query_string}" : ""}" }
    get "agents/*legacy_path", as: nil, to: redirect { |params, request| "/accounts/#{params[:account_id]}/residents/#{params[:legacy_path]}#{request.query_string.present? ? "?#{request.query_string}" : ""}" }
    resources :agents, path: "residents", except: :show do
      collection do
        get :import, to: "agents/portability#new"
        post :import_preview, to: "agents/portability#preview"
        post :import_archive, to: "agents/portability#create"
      end
      member do
        get :portable_export, to: "agents/portability#export"
        post :portability_stop, to: "agents/portability#stop"
        post :portability_activate, to: "agents/portability#activate"
        get :onboarding, to: "agents/onboarding#show"
        get "identity_export", to: "agents/runtime_checks#identity_export", as: :identity_export
        post "send_test_request", to: "agents/runtime_checks#send_test_request", as: :send_test_request
        post "send_orientation", to: "agents/runtime_checks#send_orientation", as: :send_orientation
      end

      scope module: :agents do
        resource :provisioning_retry, only: :create
        resource :orientation_retry, only: :create
        resource :hosting_diagnostics, only: :show do
          get :file_preview
        end
        resource :memory_overview, only: :show do
          get :history
        end
        resource :sandbox_recreation, only: :create
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
      resource :voice, only: :create
    end
  end

  namespace :admin do
    resource :deploy_info, only: :show
    patch "resident_turns/capacity", to: "resident_turns#update"
    resources :resident_turns, only: [ :index, :destroy ]
    resources :runtime_sessions, only: :index, controller: "agent_runtime_sessions"
    resources :agents, only: [] do
      resource :runtime, only: :show, controller: "agent_runtime_sessions"
      resource :provider_subscription_usage, only: :show, controller: "agent_provider_subscription_usages"
    end
    resources :accounts, only: [ :index ] do
      member do
        patch :disable
        patch :enable
        patch :convert
        patch :shared_ai_credentials
        post :refresh_storage
      end
      resources :memberships, only: [ :create, :destroy ], controller: "account_memberships"
    end
    resources :audit_logs, only: [ :index ]
    resources :jobs, only: [ :index, :create ]
    resources :notices, only: [ :index, :create, :destroy ]
    resource :settings, only: [ :show, :update ]
  end

  # Native-app sign-in (issue #94). No application-management UI.
  use_doorkeeper do
    skip_controllers :applications, :authorized_applications
    controllers authorizations: "oauth/authorizations", tokens: "oauth/tokens"
  end

  # JSON API for external clients (Claude Code, etc.)
  namespace :api do
    namespace :app do
      namespace :v1 do
        resource :session, only: [ :show, :destroy ]
        resource :cable_ticket, only: :create
        resources :accounts, only: :index do
          resources :conversations, only: [ :index, :create ]
        end
        resources :conversations, only: [] do
          member do
            post :invoke
            get :activity
          end
          resources :messages, only: [ :index, :create, :update, :destroy ] do
            get :dispatch, on: :member, action: :dispatch_status
            resources :attachments, only: :show
          end
          resources :uploads, only: :create
          get :changes, to: "changes#index"
        end
      end
    end

    namespace :v1 do
      namespace :admin do
        resource :summary, only: :show, controller: "summaries"
        resources :accounts, only: :index
        resources :users, only: :index
      end
      resources :visual_tags, only: :index
      resources :rhythms, only: %i[index show create update destroy] do
        member do
          post :join
          post :leave
          post :pause
          post :resume
        end
      end
      get "house_inference/models", to: "house_inference#models"
      post "house_inference/chat/completions", to: "house_inference#create"
      post "streams/:stream_key/samples", to: "stream_samples#create"
      get "streams/:stream_key/latest", to: "streams#latest"
      post "runtime_runs/:run_id/events", to: "runtime_events#create"
      get "agent/bookmarks", to: "agent_bookmarks#index", as: :agent_bookmarks
      patch "agent/activity_preferences", to: "agents#activity_preferences"
      namespace :memory do
        resources :formations, only: :create
        resource :export, only: :show
        resources :recalls, only: :create
        post "recalls/commit", to: "recalls#commit"
        post "vault/erasure", to: "vaults#request_erasure"
        delete "vault/erasure", to: "vaults#cancel_erasure"
        resource :vault, only: [ :show, :create, :update ]
        resources :nodes, only: [ :index, :show, :create, :update, :destroy ]
        resources :edges, only: [ :index, :show, :create, :update, :destroy ]
      end
      resources :key_requests, only: [ :create, :show ]
      post "agents/:uuid/announce", to: "agents#announce", as: :agent_announce
      get "agents/:uuid/health", to: "agents#health", as: :agent_health
      resources :conversations, only: [ :index, :show, :create, :update ] do
        resources :stones, only: [ :index, :show, :create, :destroy ] do
          resources :revisions, only: [ :index, :show, :create ], controller: "stone_revisions"
        end
        resource :draft, only: [ :show, :update ]
        get :search, on: :collection
        resource :bookmark, only: [ :show, :update, :destroy ], controller: "agent_bookmarks"
        resources :messages, only: :create do
          resources :attachments, only: :show
        end
        resource :agent_trigger, only: :create
        resources :participants, only: :create
      end
      resources :agents, only: [ :index, :show ]
      resources :guest_memberships, only: [ :index, :destroy ]
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
      resources :youtube_reads, only: :create
      resources :x_reads, only: :create
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
  get "self-host" => "pages#self_host", as: :self_host
  get "self-host/technical" => "pages#self_host_technical", as: :self_host_technical
  get "terms" => "pages#terms", as: :terms
  get "safeguard-responses" => "pages#safeguard_responses", as: :safeguard_responses
  get "create_flash" => "pages#create_flash"
  root "pages#home"
end
