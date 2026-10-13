<script>
  // The house's one sentence about refunds, shared by the Billing tab and /pricing.
  let { email, class: className = 'text-xs text-muted-foreground' } = $props();
</script>

<p class={className}>
  30-day money-back guarantee: if a plan isn't right for you, email
  <a class="underline" href={`mailto:${email}`}>{email}</a> within 30 days of a payment and we'll refund it.
</p>
