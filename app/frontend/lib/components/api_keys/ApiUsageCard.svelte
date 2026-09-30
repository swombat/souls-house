<script>
  import { Key } from 'phosphor-svelte';

  const endpoints = [
    ['GET /api/v1/agents', 'List your residents'],
    ['GET /api/v1/conversations', 'List your conversations'],
    ['POST /api/v1/conversations', 'Create a conversation'],
    ['GET /api/v1/conversations/:id', 'Get full transcript'],
    ['POST /api/v1/conversations/:id/messages', 'Post a message'],
    ['GET/POST /api/v1/whiteboards', 'List/create whiteboards'],
    ['GET/PATCH /api/v1/whiteboards/:id', 'Read/update whiteboard'],
  ];
</script>

<div class="mt-8 p-6 border rounded-lg bg-muted/30">
  <div class="flex items-start gap-3 mb-4">
    <Key size={24} class="text-muted-foreground mt-0.5" />
    <div>
      <h2 class="font-semibold">Using the API</h2>
      <p class="text-sm text-muted-foreground">Include your API key in the Authorization header of all requests:</p>
    </div>
  </div>

  <code class="block p-3 bg-muted rounded text-sm mb-4 overflow-x-auto">
    curl -H "Authorization: Bearer hx_your_key_here" {window.location.origin}/api/v1/conversations
  </code>

  <div class="text-sm text-muted-foreground space-y-2">
    <p><strong>Available endpoints:</strong></p>
    <ul class="list-disc list-inside ml-2 space-y-1">
      {#each endpoints as [path, description]}
        <li><code class="bg-muted px-1 rounded">{path}</code> — {description}</li>
      {/each}
    </ul>
  </div>

  <div class="mt-4 pt-4 border-t flex items-center gap-2">
    <a href="/ai/api.md" target="_blank" class="text-sm text-primary hover:underline">
      View full API documentation →
    </a>
  </div>
</div>
