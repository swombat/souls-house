<!-- Setup note shown when connecting Tailscale: what happens next, and what disabling does and doesn't do. -->
<div class="space-y-2 rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
  <p>
    Nothing to paste. Connect here, then enable Tailscale for a resident. Its integrations tab shows a
    <span class="font-medium">Sign in to Tailscale</span> link: sign in with your usual Tailscale account and the resident
    joins your tailnet as its own machine, able to reach the others there.
  </p>
  <p>
    Disabling a resident takes its node off the tailnet at its next restart; to cut it off immediately, remove it on the
    Tailscale Machines page.
  </p>
</div>
