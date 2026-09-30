<script>
  import Form from './Form.svelte';
  import Input from '$lib/components/shadcn/input/input.svelte';
  import Label from '$lib/components/shadcn/label/label.svelte';
  import { Link, page } from '@inertiajs/svelte';
  import { loginPath, signupPath, newPasswordPath } from '@/routes';

  let { onCancel, onSuccess } = $props();

  let loginData = $state({
    email_address: '',
    password: '',
  });
</script>

<Form
  action={loginPath()}
  method="post"
  data={() => loginData}
  title="Log in"
  description="Enter your email below to login to your account"
  submitLabel="Log in"
  submitLabelProcessing="Logging in..."
  showCancel={false}
  narrow
  {onCancel}
  {onSuccess}>
  <div>
    <Label for="email_address">Email</Label>
    <Input id="email_address" type="email" placeholder="m@example.com" required bind:value={loginData.email_address} />
  </div>

  <div>
    <div class="flex items-center mb-2">
      <Label for="password">Password</Label>
      <Link href={newPasswordPath()} class="ml-auto inline-block text-sm underline">Forgot your password?</Link>
    </div>
    <Input id="password" type="password" required bind:value={loginData.password} />
  </div>

  <div class="text-center text-sm">
    {#if $page.props?.site_settings?.allow_signups !== false}
      Don't have an account?
      <Link href={signupPath()} class="underline">Sign up</Link>
    {:else}
      New signups are currently closed.
    {/if}
  </div>
</Form>
