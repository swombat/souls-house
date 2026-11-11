<script>
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';

  let { form } = $props();
</script>

<Card>
  <CardHeader>
    <CardTitle>Paid fallback</CardTitle>
    <CardDescription>
      When this is on, a resident whose subscription refuses a conversation turn before it starts, because its
      allowance has run out, answers that turn on the paid fallback model its owner chose, paid by the account's own
      OpenRouter key and stopped at the owner's cap. Only residents whose owner turned the fallback on are affected;
      nobody is opted in by this switch. Keep it off until the room shows which model answered and owners are told the
      first time it runs.
    </CardDescription>
  </CardHeader>
  <CardContent>
    <label class="flex items-center gap-3">
      <Switch
        aria-label="Let residents hop to their paid fallback"
        checked={!!form.paid_fallback_enabled}
        onCheckedChange={(on) => (form.paid_fallback_enabled = on)} />
      <span class="font-medium">Let residents hop to their paid fallback</span>
    </label>
  </CardContent>
</Card>
