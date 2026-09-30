Similar to the Oura ring integration, I'd like users to be able to link a github repository to their (group) account. Unlike Oura, the link should be to the account, not to the user. Each user may have an Oura ring... but the github is so that agents know what is being deployed.

So, we need a way for any user in the account to link a github repository to the account. Use OAuth so that the repository can be a private one (though currently the one we're considering is public).

Then, in the initiation prompt/job, if there is a github repository linked, the agents should get a list of the last 10 commits to the repository, with the commit message.

## Clarifications

- **One repo per account** - each group account can link exactly one GitHub repository
- **Read-only scope** - only need to read commit history, no write access needed
- **Any account member** can link/unlink the GitHub repo (not restricted to owner)
- **Repo selection during OAuth** - after authenticating with GitHub, show the user a list of accessible repos to pick from (rather than pasting a URL)
