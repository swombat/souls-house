<script>
  import { createEventDispatcher } from 'svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { RadioGroup, RadioGroupItem } from '$lib/components/shadcn/radio-group/index.js';

  const dispatch = createEventDispatcher();

  let { canInviteOwner = false } = $props();

  let email = $state('');
  let role = $state('member');

  function handleSubmit(e) {
    e.preventDefault();
    if (email) {
      dispatch('invite', { email, role });
      email = '';
      role = 'member';
    }
  }

  function handleCancel() {
    dispatch('close');
  }
</script>

<form onsubmit={handleSubmit} class="space-y-4">
  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    <div class="space-y-2">
      <Label for="email">Email Address</Label>
      <Input type="email" id="email" bind:value={email} placeholder="colleague@example.com" required />
    </div>

    <div class="space-y-2">
      <Label>Role</Label>
      <RadioGroup bind:value={role} class="flex flex-col space-y-2">
        <div class="flex items-center space-x-2">
          <RadioGroupItem value="member" id="member" />
          <Label for="member" class="font-normal cursor-pointer">
            <span class="font-medium">Member</span> - Basic access to account resources
          </Label>
        </div>
        <div class="flex items-center space-x-2">
          <RadioGroupItem value="admin" id="admin" />
          <Label for="admin" class="font-normal cursor-pointer">
            <span class="font-medium">Admin</span> - Can manage members and settings
          </Label>
        </div>
        {#if canInviteOwner}
          <div class="flex items-center space-x-2">
            <RadioGroupItem value="owner" id="owner" />
            <Label for="owner" class="font-normal cursor-pointer">
              <span class="font-medium">Owner</span> - Full access to account and billing
            </Label>
          </div>
        {/if}
      </RadioGroup>
    </div>
  </div>

  <div class="flex justify-end space-x-3">
    <Button type="button" variant="outline" onclick={handleCancel}>Cancel</Button>
    <Button type="submit">Send Invitation</Button>
  </div>
</form>
