# Switch Component

## Installation

```bash
bunx shadcn-svelte@latest add switch
```

## Usage

```svelte
<script>
  import { Switch } from "$lib/components/ui/switch";
  import { Label } from "$lib/components/ui/label";
  
  let enabled = false;
  let notifications = true;
</script>

<!-- Basic switch -->
<Switch />

<!-- With label -->
<div class="flex items-center space-x-2">
  <Switch id="airplane-mode" />
  <Label for="airplane-mode">Airplane Mode</Label>
</div>

<!-- Controlled switch -->
<Switch bind:checked={enabled} />
<p>Feature is {enabled ? 'enabled' : 'disabled'}</p>

<!-- With description -->
<div class="flex items-center justify-between">
  <div class="space-y-0.5">
    <Label for="notifications">Notifications</Label>
    <p class="text-sm text-muted-foreground">
      Receive notifications about your account activity.
    </p>
  </div>
  <Switch id="notifications" bind:checked={notifications} />
</div>

<!-- Disabled state -->
<div class="flex items-center space-x-2">
  <Switch id="disabled" disabled />
  <Label for="disabled" class="opacity-50">Disabled switch</Label>
</div>

<!-- Settings list -->
<div class="space-y-4">
  <div class="flex items-center justify-between">
    <Label for="marketing">Marketing emails</Label>
    <Switch id="marketing" />
  </div>
  <div class="flex items-center justify-between">
    <Label for="security">Security alerts</Label>
    <Switch id="security" defaultChecked />
  </div>
  <div class="flex items-center justify-between">
    <Label for="updates">Product updates</Label>
    <Switch id="updates" />
  </div>
</div>
```

## Props

- `checked` - Switch state (boolean)
- `disabled` - Disable switch
- `id` - Switch ID for label association
- `name` - Form field name
- `value` - Switch value for forms
- `required` - Mark as required field
- `class` - Additional CSS classes

## Events

- `on:change` - Fired when switch state changes
- `on:click` - Click event handler

## Common Patterns

### Form Integration
```svelte
<script>
  let formData = {
    darkMode: false,
    autoSave: true,
    notifications: false
  };
</script>

<form>
  <div class="space-y-4">
    <div class="flex items-center justify-between">
      <Label for="dark-mode">Dark Mode</Label>
      <Switch id="dark-mode" bind:checked={formData.darkMode} />
    </div>
    <div class="flex items-center justify-between">
      <Label for="auto-save">Auto-save</Label>
      <Switch id="auto-save" bind:checked={formData.autoSave} />
    </div>
    <div class="flex items-center justify-between">
      <Label for="notifications">Notifications</Label>
      <Switch id="notifications" bind:checked={formData.notifications} />
    </div>
  </div>
</form>
```

## Documentation

- [Official Switch Documentation](https://www.shadcn-svelte.com/docs/components/switch)
- [Bits UI Switch](https://bits-ui.com/docs/components/switch)
