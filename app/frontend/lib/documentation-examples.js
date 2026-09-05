export const syncModelExample = `class Account < ApplicationRecord
  include SyncAuthorizable
  include Broadcastable
  
  # Broadcast to admin collection (for index pages)
  broadcasts_to :all
end

class AccountUser < ApplicationRecord
  include Broadcastable
  belongs_to :account
  
  # Broadcast changes to parent account
  broadcasts_to :account
end

class User < ApplicationRecord
  include Broadcastable
  has_many :accounts, through: :account_users
  
  # Broadcast to all associated accounts (auto-detected as collection)
  broadcasts_to :accounts
end`;

export const syncSvelteExample = `<script>
  import { useSync } from '$lib/use-sync';
  
  let { accounts = [], selected_account = null } = $props();
  
  // Subscribe to real-time updates
  useSync({
    'Account:all': 'accounts',  // Updates when any account changes
    [\`Account:\${selected_account?.id}\`]: 'selected_account' // Updates specific account
  });
<\/script>`;

export const broadcastsToExample = `# Controller provides props
class AccountsController < ApplicationController
  def show
    @account = current_user.accounts.find(params[:id])
    render inertia: "accounts/show", props: {
      account: @account.as_json,
      members: @account.account_users.as_json
    }
  end
end

# Models broadcast their identity
class AccountUser < ApplicationRecord
  include Broadcastable
  belongs_to :account
  
  # When AccountUser changes, broadcast to its account
  broadcasts_to :account
end`;

export const svelteChannelMapping = `// Svelte component maps channels to props
<script>
  import { useSync } from '$lib/use-sync';
  
  let { account, members } = $props();
  
  // When Account:123 broadcasts, reload both props
  useSync({
    [\`Account:\${account.id}\`]: ['account', 'members']
  });
<\/script>`;

export const multipleSyncExample = `useSync({
  'Account:all': 'accounts',
  [\`Account:\${account.id}\`]: 'account',
  [\`User:\${user.id}\`]: 'current_user',
  'SystemSetting:all': 'settings' // Admin only
});`;

export const parentChildExample = `class AccountUser < ApplicationRecord
  include Broadcastable
  
  belongs_to :account
  belongs_to :user
  
  # When AccountUser changes, broadcast to parent account
  broadcasts_to :account
end

class User < ApplicationRecord
  include Broadcastable
  
  has_many :account_users
  has_many :accounts, through: :account_users
  
  # When user changes, broadcast to all their accounts
  broadcasts_to :accounts
end`;

export const dynamicSyncExample = `import { createDynamicSync } from '$lib/use-sync';

let { accounts = [], selected_account = null } = $props();

// Create dynamic sync handler
const updateSync = createDynamicSync();

// Update subscriptions when selected_account changes
$effect(() => {
  const subs = { 'Account:all': 'accounts' };
  
  if (selected_account) {
    subs[\`Account:\${selected_account.id}\`] = 'selected_account';
  }
  
  updateSync(subs);
});`;

export const jsonAttributesBasic = `class User < ApplicationRecord
  include JsonAttributes
  
  # Specify what to include in JSON, excluding sensitive fields
  json_attributes :full_name, :site_admin, except: [:password_digest]
end

class Account < ApplicationRecord
  include JsonAttributes
  
  # Include boolean methods (the ? will be stripped in JSON)
  json_attributes :personal?, :team?, :active?, :is_site_admin, :name
end

class AccountUser < ApplicationRecord
  include JsonAttributes
  
  # Include associations with their json_attributes
  json_attributes :role, :confirmed_at, include: { user: {}, account: {} }
end`;

export const jsonAttributesController = `class AccountsController < ApplicationController
  def show
    @account = current_user.accounts.find(params[:id])
    
    render inertia: "accounts/show", props: {
      # as_json automatically uses json_attributes configuration
      account: @account.as_json,
      # Pass current_user context for authorization in nested associations
      members: @account.account_users.as_json(current_user: current_user)
    }
  end
end`;

export const jsonAttributesAdvanced = `class User < ApplicationRecord
  include JsonAttributes
  
  json_attributes :email_address, :full_name do |hash, options|
    # Add computed properties
    hash[:initials] = full_name.split.map(&:first).join
    
    # Conditional attributes based on context
    if options[:current_user]&.admin?
      hash[:last_login_at] = last_login_at
    end
    
    hash
  end
end`;

export const jsonAttributesOutput = `# Ruby model
user = User.find(1)
user.id          # => 1
user.to_param    # => "usr_abc123xyz"
user.site_admin? # => true

# JSON output
user.as_json
# => {
#   "id": "usr_abc123xyz",    # Automatically obfuscated
#   "full_name": "Jane Doe",
#   "email_address": "jane@example.com",
#   "site_admin": true         # Note: no "?" in key
#   # password_digest is excluded
# }`;
