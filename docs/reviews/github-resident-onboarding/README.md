# GitHub resident onboarding review

Issue: [#177](https://github.com/swombat/souls-house/issues/177).

Screenshots are captured from the running Rails/Inertia application by
`test/e2e/github_resident_onboarding.spec.js`, using synthetic accounts,
`example-org/example-home` and an explicitly fake token. They are not mockups.
No real identity, credentials, private memory or live GitHub repository is used.

- `01-github-request-desktop.png`: account owner's request.
- `02-pending-review.png`: waiting for account approval.
- `03-account-approval.png`: a non-site-admin account owner explicitly accepts
  continuing repository-code trust.
- `04-github-request-mobile.png`: request at a 390px viewport.
- `05-operator-trust-needed.png`: seeded home, not yet online.
- `06-import-failure-mobile.png`: safe failure with an existing home preserved.

The browser test checks the account owner's approval affordances but deliberately
does not submit approval or launch Docker. Rails tests cover
request/approval/activation and reapproval with safe doubles; a local Git fixture
exercises repository validation.
An actual GitHub/Docker/interactive-Chaos pilot is **not** claimed.

The current runtime requires an explicit operator trust step after seeding.
See [the operator and local-use guide](../../features/github-resident-onboarding.md).
This PR does not modify existing manually imported residents.
