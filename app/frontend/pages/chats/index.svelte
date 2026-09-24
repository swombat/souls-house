<script>
  import { useForm } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { ChatCircle, Plus, Sparkle, List } from 'phosphor-svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import ChatList from './ChatList.svelte';
  import { accountChatsPath } from '@/routes';

  let { chats = [], account, models = [] } = $props();

  let selectedModel = $state(models?.[0]?.model_id ?? models?.[0]?.value ?? models?.[0] ?? 'openrouter/auto');
  let sidebarOpen = $state(false);

  const createChatForm = useForm({
    chat: {
      model_id: selectedModel,
    },
  });

  function createNewChat() {
    if ($createChatForm?.data?.chat) {
      $createChatForm.data.chat.model_id = selectedModel;
    }
    $createChatForm.post(accountChatsPath(account.id));
  }

  function modelValue(model) {
    return model?.model_id ?? model?.value ?? model;
  }

  function modelLabel(model) {
    return model?.label ?? modelValue(model);
  }

  function selectedModelLabel() {
    return modelLabel(models.find((model) => modelValue(model) === selectedModel)) || 'Select AI model';
  }
</script>

<svelte:head>
  <title>Chats</title>
</svelte:head>

<div class="flex min-h-0 flex-1">
  <!-- Left sidebar: Chat list -->
  <ChatList
    {chats}
    activeChatId={null}
    accountId={account.id}
    {selectedModel}
    isOpen={sidebarOpen}
    onClose={() => (sidebarOpen = false)} />

  <!-- Right side: Welcome message -->
  <main class="flex-1 overflow-y-auto bg-background">
    <!-- Mobile header with toggle -->
    <div class="md:hidden border-b border-border bg-muted/30 px-4 py-3">
      <Button variant="ghost" size="sm" onclick={() => (sidebarOpen = true)} class="h-8 w-8 p-0">
        <List size={20} />
      </Button>
    </div>

    <div class="flex items-center justify-center h-full">
      <div class="text-center max-w-md mx-auto px-4">
        <div
          class="w-16 h-16 md:w-20 md:h-20 mx-auto mb-4 md:mb-6 rounded-full bg-primary/10 flex items-center justify-center">
          <ChatCircle size={32} class="text-primary md:hidden" />
          <ChatCircle size={40} class="text-primary hidden md:block" />
        </div>

        <h1 class="text-xl md:text-2xl font-semibold mb-3">Start a conversation</h1>
        <p class="text-muted-foreground mb-8">
          Choose an AI model and begin chatting. Your conversations will appear in the sidebar.
        </p>

        <Card.Root class="max-w-sm mx-auto">
          <Card.Header class="pb-4 space-y-4">
            <div class="flex items-center justify-between gap-3">
              <Card.Title class="text-lg flex items-center gap-2">
                <Sparkle size={20} class="text-primary" />
                New Chat
              </Card.Title>
              <Select.Root
                value={selectedModel}
                onValueChange={(value) => {
                  selectedModel = value;
                  if ($createChatForm?.data?.chat) {
                    $createChatForm.data.chat.model_id = value;
                  }
                }}>
                <Select.Trigger class="w-48" id="model-select">
                  {selectedModelLabel()}
                </Select.Trigger>
                <Select.Content sideOffset={4}>
                  {#each models as model (modelValue(model))}
                    <Select.Item value={modelValue(model)} label={modelLabel(model)}>
                      {modelLabel(model)}
                    </Select.Item>
                  {/each}
                </Select.Content>
              </Select.Root>
            </div>
            <p class="text-sm text-muted-foreground text-left">
              Choose which model to use when starting this conversation.
            </p>
          </Card.Header>
          <Card.Content class="space-y-4">
            <Button onclick={createNewChat} disabled={$createChatForm.processing} class="w-full">
              {#if $createChatForm.processing}
                Creating...
              {:else}
                <Plus size={16} class="mr-2" />
                Start New Chat
              {/if}
            </Button>
          </Card.Content>
        </Card.Root>
      </div>
    </div>
  </main>
</div>
