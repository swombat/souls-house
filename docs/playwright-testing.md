# Browser Testing Guide (agent-browser)

This document covers how to use agent-browser for testing and interacting with the souls.house application during development.

## Overview

agent-browser is a CLI tool that uses ref-based element selection from accessibility snapshots. It's much more natural for AI agents than CSS selectors — you snapshot the page, get labeled refs (@e1, @e2, etc.), and interact using those refs.

## Core Workflow

```bash
# 1. Open a URL
agent-browser open http://localhost:3100

# 2. Snapshot interactive elements
agent-browser snapshot -i

# 3. Interact using refs
agent-browser click @e3
agent-browser fill @e2 "some text"

# 4. Re-snapshot after DOM changes
agent-browser snapshot -i
```

## CRITICAL NAVIGATION RULES

### Don't guess URLs — navigate through the app!

1. Open the root: `agent-browser open http://localhost:3100`
2. Snapshot to see what's on the page: `agent-browser snapshot -i`
3. Click through the interface using refs to reach your destination

**WHY:** Direct navigation to deep URLs often fails because:
- The session may not be properly initialized
- Required data may not be loaded
- The URL structure might be wrong
- Authentication might not be properly handled

**NEVER GUESS THE URL.** Log in, let the app show you the default page, and use the navigation controls on-page to get where you want to be.

When you check a page is working, ALWAYS check the contents, not just that the page loaded! Take a snapshot or screenshot to verify you're not looking at an error page.

## Application Details

- The app is running on **http://localhost:3100** — not https!
- If you need to restart it, don't — just ask the user to restart it for you.

## Logging In

```bash
agent-browser open http://localhost:3100
agent-browser snapshot -i
# You'll see textbox refs for Email and Password, and a Sign In button
agent-browser fill @e2 "daniel@granttree.co.uk"
agent-browser fill @e3 "password"
agent-browser click @e5
agent-browser wait 2000
agent-browser snapshot -i  # Verify you're logged in
```

The dev environment auto-fills credentials, so you may just need to click the Sign In button.

## Screenshots

```bash
# Save a screenshot to verify what you see
agent-browser screenshot ~/Downloads/screenshots/page.png

# Then read it to view visually
# Use the Read tool on the saved .png file
```

## Useful Commands

```bash
agent-browser get url              # Check current URL
agent-browser get title            # Check page title
agent-browser get text @e1         # Get text of an element
agent-browser scroll down 500      # Scroll down
agent-browser back                 # Go back
agent-browser close                # Close browser when done
```

## Debugging

If something seems wrong (page not loading, unexpected content), take a screenshot and read it:

```bash
agent-browser screenshot /tmp/debug.png
# Then use Read tool to view it
```

You can also run in headed mode to see the browser visually:

```bash
agent-browser --headed open http://localhost:3100
```
