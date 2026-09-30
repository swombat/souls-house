Ok, so, so far, this development has been happening in an open source repository called "HelixKit" that was meant to be tied to GrantTree. It's deployed on https://helix-kit.granttree.co.uk.

Most of the changes so far make sense for any app that's going to offer some kind of agentic group conversation model. But I want to now split it as there are some changes that are very specific to the "Nexus" application that Paulina, the cofounder of GrantTree and also of this new project called Nexus (for now), is envisioning, like oura ring integration and other such things.

So, I want to fork the project (but ideally continue to get changes from upstream), and deploy on a new server, rebrand, etc.

It is very important that the data currently in the helixkit production server is migrated over to the new server (likely will be at nexus.swombat.io, deployed on the same physical server).

What's the best approach to doing this? Bearing in mind that Github has some restrictions about forking your own repository (annoyingly).

## Clarifications

1. **Git strategy**: Maintain connection to upstream HelixKit to pull future generic improvements. Need a branching/remote strategy that allows syncing.

2. **Rebranding scope**: App name/logo/colors, new domain (nexus.swombat.io), email configs. Can reuse existing credentials initially, will create new ones eventually.

3. **Database migration**: One-time migration from HelixKit production to new Nexus database. HelixKit DB will eventually be reset. Both apps on same physical server.

4. **Development sequence**: Get fork operational first, then add Nexus-specific features (oura ring integration, etc).

5. **HelixKit future**: Will continue to be developed as a generic starter template. Nexus should be able to pull generic improvements from it.