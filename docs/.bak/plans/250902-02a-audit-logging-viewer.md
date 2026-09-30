# Audit Log Viewer Implementation Spec

## Executive Summary

This specification details the implementation of a comprehensive audit log viewer for the admin interface. The viewer will follow a master/detail pattern similar to the existing admin accounts page, featuring server-side filtered and paginated audit logs with real-time synchronization and URL state management.

## Architecture Overview

### Component Structure
```
Admin::AuditLogsController (Rails)
  ↓ Inertia props
admin/audit-logs.svelte (Main page component)
  ├── AuditLogFilters.svelte (Filter controls)
  ├── AuditLogList.svelte (Paginated list)
  └── AuditLogDrawer.svelte (Detail view)
```

### Data Flow
1. Controller serves paginated, filtered audit logs via Inertia
2. URL parameters maintain filter and selection state
3. Real-time updates via ActionCable broadcast new events
4. Drawer component displays detailed event information

## Backend Architecture

### 1. Controller Implementation

#### `app/controllers/admin/audit_logs_controller.rb`

```ruby
class Admin::AuditLogsController < ApplicationController
  before_action :require_site_admin
  
  def index
    @audit_logs = AuditLog.filter_and_paginate(filter_params)
    @selected_log = AuditLog.find(params[:log_id]) if params[:log_id].present?
    
    render inertia: "admin/audit-logs", props: {
      audit_logs: serialize_logs(@audit_logs),
      selected_log: serialize_detailed_log(@selected_log),
      filters: available_filters,
      pagination: pagination_props(@audit_logs),
      current_filters: filter_params
    }
  end
  
  private
  
  def filter_params
    params.permit(:user_id, :account_id, :action, :auditable_type, 
                  :date_from, :date_to, :page, :per_page)
          .with_defaults(page: 1, per_page: 10)
  end
  
  def available_filters
    {
      users: User.select(:id, :email_address).order(:email_address),
      accounts: Account.select(:id, :name).order(:name),
      actions: AuditLog.distinct_actions,
      object_types: AuditLog.distinct_auditable_types
    }
  end
  
  def serialize_logs(logs)
    logs.includes(:user, :account, :auditable).map do |log|
      {
        id: log.id,
        action: log.action,
        display_action: log.display_action,
        user: log.user&.slice(:id, :email_address),
        account: log.account&.slice(:id, :name),
        auditable_type: log.auditable_type,
        auditable_id: log.auditable_id,
        auditable_display: log.auditable_display_name,
        created_at: log.created_at.iso8601,
        summary: log.summary_text
      }
    end
  end
  
  def serialize_detailed_log(log)
    return nil unless log
    
    {
      id: log.id,
      action: log.action,
      display_action: log.display_action,
      user: log.user&.as_json(only: [:id, :email_address, :name]),
      account: log.account&.as_json(only: [:id, :name, :account_type]),
      auditable_type: log.auditable_type,
      auditable_id: log.auditable_id,
      auditable: log.auditable&.as_json,
      data: log.data,
      ip_address: log.ip_address,
      user_agent: log.user_agent,
      created_at: log.created_at.iso8601,
      formatted_data: log.formatted_data
    }
  end
  
  def pagination_props(logs)
    {
      current_page: logs.current_page,
      total_pages: logs.total_pages,
      total_count: logs.total_count,
      per_page: logs.limit_value,
      next_page: logs.next_page,
      prev_page: logs.prev_page
    }
  end
  
  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end
end
```

### 2. Model Enhancements

#### `app/models/audit_log.rb` (Enhanced)

```ruby
class AuditLog < ApplicationRecord
  include Broadcastable
  
  # Existing associations
  belongs_to :user, optional: true
  belongs_to :account, optional: true
  belongs_to :auditable, polymorphic: true, optional: true
  
  # Validations
  validates :action, presence: true
  
  # Broadcasting configuration
  broadcasts_to :all
  broadcasts_refresh_prop "audit_logs", collection: true
  
  # Scopes for filtering
  scope :recent, -> { order(created_at: :desc) }
  scope :for_account, ->(account) { where(account: account) }
  scope :for_user, ->(user) { where(user: user) }
  scope :for_action, ->(action) { where(action: action) }
  scope :for_auditable_type, ->(type) { where(auditable_type: type) }
  scope :date_range, ->(from, to) { 
    query = self
    query = query.where("created_at >= ?", from) if from.present?
    query = query.where("created_at <= ?", to) if to.present?
    query
  }
  
  # Pagination concern (Fat Model pattern)
  def self.filter_and_paginate(params)
    logs = recent
    
    # Apply filters
    logs = logs.for_user(params[:user_id]) if params[:user_id].present?
    logs = logs.for_account(params[:account_id]) if params[:account_id].present?
    logs = logs.for_action(params[:action]) if params[:action].present?
    logs = logs.for_auditable_type(params[:auditable_type]) if params[:auditable_type].present?
    logs = logs.date_range(params[:date_from], params[:date_to])
    
    # Paginate
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 10).to_i
    
    logs.paginate(page: page, per_page: per_page)
  end
  
  # Simple pagination implementation (avoiding external gems)
  scope :paginate, ->(page: 1, per_page: 10) {
    offset = (page - 1) * per_page
    limit(per_page).offset(offset).extending(PaginationExtension)
  }
  
  module PaginationExtension
    def current_page
      (offset_value / limit_value) + 1
    end
    
    def total_pages
      (total_count.to_f / limit_value).ceil
    end
    
    def total_count
      @total_count ||= except(:limit, :offset).count
    end
    
    def next_page
      current_page < total_pages ? current_page + 1 : nil
    end
    
    def prev_page
      current_page > 1 ? current_page - 1 : nil
    end
  end
  
  # Helper methods for display
  def display_action
    action.to_s.humanize
  end
  
  def auditable_display_name
    return nil unless auditable
    
    if auditable.respond_to?(:name)
      "#{auditable_type}: #{auditable.name}"
    elsif auditable.respond_to?(:email_address)
      "#{auditable_type}: #{auditable.email_address}"
    else
      "#{auditable_type} ##{auditable_id}"
    end
  end
  
  def summary_text
    "#{display_action} #{auditable_display_name || auditable_type}".strip
  end
  
  def formatted_data
    return {} if data.blank?
    
    # Format the JSON data for display
    data.transform_keys { |k| k.to_s.humanize }
  end
  
  # Class methods for filters
  def self.distinct_actions
    distinct.pluck(:action).compact.sort
  end
  
  def self.distinct_auditable_types
    distinct.pluck(:auditable_type).compact.sort
  end
end
```

## Frontend Components

### 1. Main Page Component

#### `app/frontend/pages/admin/audit-logs.svelte`

```svelte
<script>
  import { page } from '@inertiajs/svelte';
  import { router } from '@inertiajs/svelte';
  import AuditLogFilters from '$lib/components/admin/AuditLogFilters.svelte';
  import AuditLogList from '$lib/components/admin/AuditLogList.svelte';
  import AuditLogDrawer from '$lib/components/admin/AuditLogDrawer.svelte';
  import { createDynamicSync } from '$lib/use-sync';
  
  let { 
    audit_logs = [], 
    selected_log = null,
    filters = {},
    pagination = {},
    current_filters = {}
  } = $props();
  
  let drawerOpen = $state(false);
  
  // Dynamic synchronization for real-time updates
  const updateSync = createDynamicSync();
  
  $effect(() => {
    const subs = {
      'AuditLog:all': 'audit_logs', // Subscribe to all new audit logs
    };
    
    if (selected_log) {
      subs[`AuditLog:${selected_log.id}`] = 'selected_log';
    }
    
    updateSync(subs);
  });
  
  // Open drawer when log is selected
  $effect(() => {
    drawerOpen = !!selected_log;
  });
  
  function updateFilters(newFilters) {
    const params = new URLSearchParams();
    
    Object.entries(newFilters).forEach(([key, value]) => {
      if (value) params.append(key, value);
    });
    
    // Reset to page 1 when filters change
    params.set('page', '1');
    
    router.visit(`/admin/audit-logs?${params.toString()}`, {
      preserveState: false,
      preserveScroll: false,
    });
  }
  
  function selectLog(logId) {
    const params = new URLSearchParams(window.location.search);
    params.set('log_id', logId);
    
    router.visit(`/admin/audit-logs?${params.toString()}`, {
      preserveState: true,
      preserveScroll: true,
      only: ['selected_log'],
    });
  }
  
  function closeDrawer() {
    const params = new URLSearchParams(window.location.search);
    params.delete('log_id');
    
    router.visit(`/admin/audit-logs?${params.toString()}`, {
      preserveState: true,
      preserveScroll: true,
      only: ['selected_log'],
    });
  }
  
  function changePage(page) {
    const params = new URLSearchParams(window.location.search);
    params.set('page', page);
    
    router.visit(`/admin/audit-logs?${params.toString()}`, {
      preserveState: true,
      preserveScroll: false,
    });
  }
</script>

<div class="container mx-auto px-4 py-6">
  <h1 class="text-2xl font-bold mb-6">Audit Logs</h1>
  
  <AuditLogFilters 
    {filters}
    {current_filters}
    onchange={updateFilters}
  />
  
  <AuditLogList 
    logs={audit_logs}
    {pagination}
    selectedId={selected_log?.id}
    onselect={selectLog}
    onpagechange={changePage}
  />
  
  <AuditLogDrawer 
    log={selected_log}
    open={drawerOpen}
    onclose={closeDrawer}
  />
</div>
```

### 2. Filter Component

#### `app/frontend/lib/components/admin/AuditLogFilters.svelte`

```svelte
<script>
  import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '$lib/components/shadcn/select';
  import { Input } from '$lib/components/shadcn/input';
  import { Button } from '$lib/components/shadcn/button';
  import { Badge } from '$lib/components/shadcn/badge';
  
  let { filters = {}, current_filters = {}, onchange } = $props();
  
  let localFilters = $state({ ...current_filters });
  let searchUser = $state('');
  let searchAccount = $state('');
  
  // Filtered lists for typeahead
  const filteredUsers = $derived(
    searchUser 
      ? filters.users?.filter(u => 
          u.email_address.toLowerCase().includes(searchUser.toLowerCase())
        )
      : filters.users
  );
  
  const filteredAccounts = $derived(
    searchAccount
      ? filters.accounts?.filter(a => 
          a.name.toLowerCase().includes(searchAccount.toLowerCase())
        )
      : filters.accounts
  );
  
  function applyFilters() {
    onchange(localFilters);
  }
  
  function clearFilters() {
    localFilters = {};
    searchUser = '';
    searchAccount = '';
    onchange({});
  }
  
  function removeFilter(key) {
    delete localFilters[key];
    localFilters = { ...localFilters };
    onchange(localFilters);
  }
  
  const activeFilterCount = $derived(
    Object.keys(localFilters).filter(k => 
      localFilters[k] && !['page', 'per_page'].includes(k)
    ).length
  );
</script>

<div class="bg-card border rounded-lg p-4 mb-6">
  <div class="flex items-center justify-between mb-4">
    <h2 class="text-lg font-semibold">Filters</h2>
    {#if activeFilterCount > 0}
      <Badge variant="secondary">{activeFilterCount} active</Badge>
    {/if}
  </div>
  
  <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 gap-4">
    <!-- User Filter with Typeahead -->
    <div class="relative">
      <label class="text-sm font-medium mb-1 block">User</label>
      <Select bind:value={localFilters.user_id}>
        <SelectTrigger>
          <SelectValue placeholder="All users" />
        </SelectTrigger>
        <SelectContent>
          <div class="p-2">
            <Input
              type="search"
              placeholder="Search users..."
              bind:value={searchUser}
              class="mb-2"
            />
          </div>
          <SelectItem value="">All users</SelectItem>
          {#each filteredUsers || [] as user}
            <SelectItem value={user.id}>{user.email_address}</SelectItem>
          {/each}
        </SelectContent>
      </Select>
    </div>
    
    <!-- Account Filter with Typeahead -->
    <div class="relative">
      <label class="text-sm font-medium mb-1 block">Account</label>
      <Select bind:value={localFilters.account_id}>
        <SelectTrigger>
          <SelectValue placeholder="All accounts" />
        </SelectTrigger>
        <SelectContent>
          <div class="p-2">
            <Input
              type="search"
              placeholder="Search accounts..."
              bind:value={searchAccount}
              class="mb-2"
            />
          </div>
          <SelectItem value="">All accounts</SelectItem>
          {#each filteredAccounts || [] as account}
            <SelectItem value={account.id}>{account.name}</SelectItem>
          {/each}
        </SelectContent>
      </Select>
    </div>
    
    <!-- Action Filter -->
    <div>
      <label class="text-sm font-medium mb-1 block">Action</label>
      <Select bind:value={localFilters.action}>
        <SelectTrigger>
          <SelectValue placeholder="All actions" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="">All actions</SelectItem>
          {#each filters.actions || [] as action}
            <SelectItem value={action}>{action}</SelectItem>
          {/each}
        </SelectContent>
      </Select>
    </div>
    
    <!-- Object Type Filter -->
    <div>
      <label class="text-sm font-medium mb-1 block">Object Type</label>
      <Select bind:value={localFilters.auditable_type}>
        <SelectTrigger>
          <SelectValue placeholder="All types" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="">All types</SelectItem>
          {#each filters.object_types || [] as type}
            <SelectItem value={type}>{type}</SelectItem>
          {/each}
        </SelectContent>
      </Select>
    </div>
    
    <!-- Date Range -->
    <div>
      <label class="text-sm font-medium mb-1 block">Date Range</label>
      <div class="flex gap-2">
        <Input
          type="date"
          bind:value={localFilters.date_from}
          class="flex-1"
        />
        <Input
          type="date"
          bind:value={localFilters.date_to}
          class="flex-1"
        />
      </div>
    </div>
  </div>
  
  <!-- Active Filters Display -->
  {#if activeFilterCount > 0}
    <div class="flex flex-wrap gap-2 mt-4 pt-4 border-t">
      {#each Object.entries(localFilters) as [key, value]}
        {#if value && !['page', 'per_page'].includes(key)}
          <Badge variant="outline" class="pr-1">
            <span class="mr-1">{key.replace('_', ' ')}: {value}</span>
            <button
              onclick={() => removeFilter(key)}
              class="ml-1 hover:text-destructive"
            >
              ×
            </button>
          </Badge>
        {/if}
      {/each}
    </div>
  {/if}
  
  <div class="flex gap-2 mt-4">
    <Button onclick={applyFilters} size="sm">Apply Filters</Button>
    {#if activeFilterCount > 0}
      <Button onclick={clearFilters} variant="outline" size="sm">Clear All</Button>
    {/if}
  </div>
</div>
```

### 3. List Component

#### `app/frontend/lib/components/admin/AuditLogList.svelte`

```svelte
<script>
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Button } from '$lib/components/shadcn/button';
  import { formatDistanceToNow } from 'date-fns';
  
  let { logs = [], pagination = {}, selectedId = null, onselect, onpagechange } = $props();
  
  function formatTime(dateString) {
    return formatDistanceToNow(new Date(dateString), { addSuffix: true });
  }
  
  function getActionColor(action) {
    const colors = {
      create: 'success',
      update: 'info',
      delete: 'destructive',
      login: 'secondary',
      logout: 'secondary',
    };
    return colors[action] || 'default';
  }
</script>

<div class="bg-card border rounded-lg">
  <Table>
    <TableHeader>
      <TableRow>
        <TableHead class="w-[180px]">Time</TableHead>
        <TableHead class="w-[120px]">Action</TableHead>
        <TableHead>User</TableHead>
        <TableHead>Account</TableHead>
        <TableHead>Object</TableHead>
        <TableHead class="w-[100px]">Details</TableHead>
      </TableRow>
    </TableHeader>
    <TableBody>
      {#if logs.length === 0}
        <TableRow>
          <TableCell colspan="6" class="text-center text-muted-foreground py-8">
            No audit logs found
          </TableCell>
        </TableRow>
      {:else}
        {#each logs as log (log.id)}
          <TableRow 
            class="cursor-pointer hover:bg-muted/50 {selectedId === log.id ? 'bg-primary/10' : ''}"
            onclick={() => onselect(log.id)}
          >
            <TableCell class="font-mono text-sm">
              {formatTime(log.created_at)}
            </TableCell>
            <TableCell>
              <Badge variant={getActionColor(log.action)}>
                {log.display_action}
              </Badge>
            </TableCell>
            <TableCell class="text-sm">
              {log.user?.email_address || 'System'}
            </TableCell>
            <TableCell class="text-sm">
              {log.account?.name || '-'}
            </TableCell>
            <TableCell class="text-sm">
              {log.auditable_display || log.auditable_type || '-'}
            </TableCell>
            <TableCell>
              <Button 
                size="sm" 
                variant="ghost"
                onclick={(e) => {
                  e.stopPropagation();
                  onselect(log.id);
                }}
              >
                View
              </Button>
            </TableCell>
          </TableRow>
        {/each}
      {/if}
    </TableBody>
  </Table>
  
  {#if pagination.total_pages > 1}
    <div class="flex items-center justify-between p-4 border-t">
      <div class="text-sm text-muted-foreground">
        Page {pagination.current_page} of {pagination.total_pages}
        ({pagination.total_count} total records)
      </div>
      <div class="flex gap-2">
        <Button
          size="sm"
          variant="outline"
          disabled={!pagination.prev_page}
          onclick={() => onpagechange(pagination.prev_page)}
        >
          Previous
        </Button>
        
        {#each Array(Math.min(5, pagination.total_pages)) as _, i}
          {@const pageNum = 
            pagination.current_page <= 3 ? i + 1 :
            pagination.current_page >= pagination.total_pages - 2 ? 
              pagination.total_pages - 4 + i :
              pagination.current_page - 2 + i
          }
          {#if pageNum > 0 && pageNum <= pagination.total_pages}
            <Button
              size="sm"
              variant={pageNum === pagination.current_page ? 'default' : 'outline'}
              onclick={() => onpagechange(pageNum)}
            >
              {pageNum}
            </Button>
          {/if}
        {/each}
        
        <Button
          size="sm"
          variant="outline"
          disabled={!pagination.next_page}
          onclick={() => onpagechange(pagination.next_page)}
        >
          Next
        </Button>
      </div>
    </div>
  {/if}
</div>
```

### 4. Drawer Component

#### `app/frontend/lib/components/admin/AuditLogDrawer.svelte`

```svelte
<script>
  import { Drawer, DrawerContent, DrawerHeader, DrawerTitle, DrawerDescription, DrawerFooter, DrawerClose } from '$lib/components/shadcn/drawer';
  import { Button } from '$lib/components/shadcn/button';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  
  let { log = null, open = false, onclose } = $props();
  
  function formatDateTime(dateString) {
    return new Date(dateString).toLocaleString('en-US', {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
  }
  
  function formatJson(data) {
    if (!data || Object.keys(data).length === 0) return null;
    return JSON.stringify(data, null, 2);
  }
</script>

<Drawer {open} onOpenChange={(state) => !state && onclose()}>
  <DrawerContent class="h-[80vh]">
    {#if log}
      <DrawerHeader>
        <DrawerTitle>
          Audit Log Details
          <Badge variant="outline" class="ml-2">#{log.id}</Badge>
        </DrawerTitle>
        <DrawerDescription>
          {log.display_action} - {formatDateTime(log.created_at)}
        </DrawerDescription>
      </DrawerHeader>
      
      <div class="overflow-y-auto flex-1 px-6">
        <div class="grid gap-4 py-4">
          <!-- Basic Information -->
          <Card>
            <CardHeader>
              <CardTitle class="text-base">Event Information</CardTitle>
            </CardHeader>
            <CardContent class="grid grid-cols-2 gap-4">
              <div>
                <label class="text-sm font-medium text-muted-foreground">Action</label>
                <p class="font-medium">{log.display_action}</p>
              </div>
              <div>
                <label class="text-sm font-medium text-muted-foreground">Timestamp</label>
                <p class="font-mono text-sm">{formatDateTime(log.created_at)}</p>
              </div>
              <div>
                <label class="text-sm font-medium text-muted-foreground">User</label>
                <p>
                  {#if log.user}
                    {log.user.email_address}
                    {#if log.user.name}
                      <span class="text-muted-foreground">({log.user.name})</span>
                    {/if}
                  {:else}
                    <span class="text-muted-foreground">System</span>
                  {/if}
                </p>
              </div>
              <div>
                <label class="text-sm font-medium text-muted-foreground">Account</label>
                <p>
                  {#if log.account}
                    {log.account.name}
                    <Badge variant="outline" class="ml-1 text-xs">
                      {log.account.account_type}
                    </Badge>
                  {:else}
                    <span class="text-muted-foreground">N/A</span>
                  {/if}
                </p>
              </div>
            </CardContent>
          </Card>
          
          <!-- Object Information -->
          {#if log.auditable_type}
            <Card>
              <CardHeader>
                <CardTitle class="text-base">Affected Object</CardTitle>
              </CardHeader>
              <CardContent>
                <div class="space-y-2">
                  <div>
                    <label class="text-sm font-medium text-muted-foreground">Type</label>
                    <p class="font-medium">{log.auditable_type}</p>
                  </div>
                  <div>
                    <label class="text-sm font-medium text-muted-foreground">ID</label>
                    <p class="font-mono">{log.auditable_id}</p>
                  </div>
                  {#if log.auditable}
                    <div>
                      <label class="text-sm font-medium text-muted-foreground">Current State</label>
                      <pre class="bg-muted p-2 rounded text-xs overflow-x-auto">
{formatJson(log.auditable)}
                      </pre>
                    </div>
                  {/if}
                </div>
              </CardContent>
            </Card>
          {/if}
          
          <!-- Data/Changes -->
          {#if log.data && Object.keys(log.data).length > 0}
            <Card>
              <CardHeader>
                <CardTitle class="text-base">Event Data</CardTitle>
              </CardHeader>
              <CardContent>
                <pre class="bg-muted p-3 rounded text-sm overflow-x-auto">
{formatJson(log.formatted_data || log.data)}
                </pre>
              </CardContent>
            </Card>
          {/if}
          
          <!-- Request Information -->
          {#if log.ip_address || log.user_agent}
            <Card>
              <CardHeader>
                <CardTitle class="text-base">Request Information</CardTitle>
              </CardHeader>
              <CardContent class="space-y-2">
                {#if log.ip_address}
                  <div>
                    <label class="text-sm font-medium text-muted-foreground">IP Address</label>
                    <p class="font-mono">{log.ip_address}</p>
                  </div>
                {/if}
                {#if log.user_agent}
                  <div>
                    <label class="text-sm font-medium text-muted-foreground">User Agent</label>
                    <p class="text-sm break-all">{log.user_agent}</p>
                  </div>
                {/if}
              </CardContent>
            </Card>
          {/if}
        </div>
      </div>
      
      <DrawerFooter>
        <DrawerClose asChild>
          <Button variant="outline">Close</Button>
        </DrawerClose>
      </DrawerFooter>
    {/if}
  </DrawerContent>
</Drawer>
```

## Routes Configuration

### `config/routes.rb` (Addition)

```ruby
namespace :admin do
  resources :accounts, only: [:index]
  resources :audit_logs, only: [:index]  # Add this line
end
```

## Real-time Synchronization

The audit log viewer will leverage the existing `Broadcastable` concern:

1. **New logs appear automatically** - When new audit logs are created, they broadcast to the `AuditLog:all` channel
2. **List updates in real-time** - The frontend subscribes to this channel and refreshes the list
3. **Maintains filters and pagination** - Updates preserve current filter and page state
4. **Selected log persists** - If viewing a specific log, the drawer remains open during updates

## URL State Management

All filter parameters and selections are maintained in the URL:

```
/admin/audit-logs?user_id=123&account_id=456&action=update&page=2&log_id=789
```

This enables:
- **Shareable links** - Users can share specific filtered views
- **Browser navigation** - Back/forward buttons work correctly
- **Bookmarkable states** - Specific views can be bookmarked
- **Refresh persistence** - Page refreshes maintain state

## Performance Considerations

### Database Optimization

1. **Existing Indexes** (Already in place):
   - `index_audit_logs_on_created_at`
   - `index_audit_logs_on_account_id_and_created_at`
   - `index_audit_logs_on_action`
   - `index_audit_logs_on_auditable_type_and_auditable_id`
   - `index_audit_logs_on_user_id`

2. **Query Optimization**:
   - Use `includes(:user, :account, :auditable)` to prevent N+1 queries
   - Paginate with limit/offset for predictable performance
   - Filter on indexed columns for fast lookups

3. **Caching Strategy**:
   - Cache filter options (users, accounts, actions) with 5-minute TTL
   - Use Rails fragment caching for rendered log rows
   - Leverage browser caching for static filter data

### Frontend Performance

1. **Virtual scrolling** - Consider implementing for large datasets (future enhancement)
2. **Debounced search** - Add debounce to typeahead filters
3. **Lazy loading** - Load drawer content only when opened
4. **Optimistic UI** - Show loading states during transitions

## Testing Strategy

### Backend Tests

- [ ] Controller tests for authorization and filtering
- [ ] Model tests for scopes and pagination
- [ ] Integration tests for real-time broadcasting
- [ ] Performance tests for large datasets

### Frontend Tests

- [ ] Component unit tests for filters and list
- [ ] Integration tests for URL state management
- [ ] E2E tests for complete user workflows
- [ ] Accessibility tests for keyboard navigation

## Implementation Checklist

### Phase 1: Backend Foundation
- [ ] Enhance AuditLog model with pagination and filtering methods
- [ ] Create Admin::AuditLogsController
- [ ] Add routes for audit logs
- [ ] Test controller with various filter combinations
- [ ] Verify broadcasting configuration

### Phase 2: Core Frontend Components
- [ ] Create main audit-logs.svelte page component
- [ ] Implement AuditLogFilters component with typeahead
- [ ] Build AuditLogList with pagination controls
- [ ] Add basic drawer without detailed formatting
- [ ] Test real-time synchronization

### Phase 3: Enhanced Features
- [ ] Implement detailed drawer view with formatted data
- [ ] Add date range picker functionality
- [ ] Enhance typeahead search for users/accounts
- [ ] Add export functionality (CSV/JSON)
- [ ] Implement keyboard shortcuts

### Phase 4: Polish & Optimization
- [ ] Add loading states and error handling
- [ ] Implement caching for filter options
- [ ] Optimize queries for large datasets
- [ ] Add comprehensive test coverage
- [ ] Performance profiling and optimization

### Phase 5: Future Enhancements
- [ ] Advanced search with full-text capability
- [ ] Audit log analytics dashboard
- [ ] Configurable retention policies
- [ ] Bulk operations (archive, export)
- [ ] Webhook notifications for specific events

## Security Considerations

1. **Admin-only access** - Enforced via `require_site_admin` before_action
2. **No data modification** - Read-only interface
3. **Filtered data exposure** - Only show relevant fields in list view
4. **Rate limiting** - Consider adding for API endpoints
5. **Audit log integrity** - Logs are immutable once created

## Edge Cases & Error Handling

1. **Empty states** - Clear messaging when no logs match filters
2. **Deleted associations** - Handle when user/account/auditable is deleted
3. **Large datasets** - Graceful degradation with pagination limits
4. **Network failures** - Retry logic for real-time updates
5. **Invalid filters** - Validation and user feedback
6. **Timezone handling** - Display times in user's local timezone

## Conclusion

This implementation provides a robust, scalable audit log viewer that follows Rails best practices while leveraging modern frontend capabilities. The fat model/skinny controller pattern keeps business logic organized, while Svelte 5's reactivity and Inertia's seamless integration provide an excellent user experience.

The system is designed to handle growth, with pagination and filtering performed efficiently on the server, real-time updates that don't disrupt user flow, and URL state management that makes the interface shareable and bookmarkable.