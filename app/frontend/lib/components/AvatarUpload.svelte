<script>
  // Your picture in Settings: drop it, paste it, pick it, or paste where it lives.
  import Avatar from './Avatar.svelte';
  import AvatarPicker from './AvatarPicker.svelte';

  let { user, onUpdate = () => {} } = $props();
</script>

<div class="max-w-md">
  <AvatarPicker
    uploadPath="/user/avatar"
    deletePath="/user/avatar"
    currentUrl={user?.avatar_url}
    removeLabel="Remove avatar"
    onDone={onUpdate}>
    <Avatar {user} size="xl" />
  </AvatarPicker>
</div>
