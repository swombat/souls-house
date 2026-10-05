<!-- Setup note shown when connecting Tailscale: what the key must be, and what disabling does and doesn't do. -->
<div class="space-y-2 rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
  <p>
    <a
      href="https://login.tailscale.com/admin/settings/keys"
      target="_blank"
      rel="noopener noreferrer"
      class="font-medium text-primary underline underline-offset-4">
      Generate an auth key
    </a>
    that is reusable, pre-approved, and tagged. Each resident you enable joins as its own node with that tag, and your tailnet
    policy for the tag decides what it can reach.
  </p>
  <p>
    Residents can read this key, and a reusable key can add further nodes until it expires or you revoke it. Disabling a
    resident here takes its node off the tailnet at its next rebuild; for immediate cutoff, remove the node in the
    Tailscale admin console.
  </p>
</div>
