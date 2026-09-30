<script>
</script>

<section class="mt-12 border-b pb-10" aria-labelledby="helper-heading">
  <p class="step-label">Step 0 · only if you need it</p>
  <h2 id="helper-heading" class="mt-2 text-2xl font-semibold tracking-tight">Get an agent to help you.</h2>
  <p class="mt-3 text-muted-foreground">
    Already use Claude Code, Chaos, Codex, or an agent app? You can start there and skip to Step 1.
  </p>
  <details class="mt-5 rounded-xl border p-5">
    <summary class="cursor-pointer font-medium">I don't have an agent yet</summary>
    <div class="mt-4 space-y-4 text-sm leading-relaxed">
      <p>
        <strong>A simple terminal option is Claude Code.</strong> A terminal is just an app where you type commands. Install
        it on the computer you're using now—even if the house will live somewhere else.
      </p>
      <ol class="list-decimal space-y-3 pl-5">
        <li>
          On <strong>Mac or Linux</strong>, open the app called <strong>Terminal</strong> and paste this official
          installer command, then press Enter:
          <pre class="command"><code>curl -fsSL https://claude.ai/install.sh | bash</code></pre>
          <p>On <strong>Windows</strong>, search the Start menu for <strong>PowerShell</strong>, open it, and use:</p>
          <pre class="command"><code>irm https://claude.ai/install.ps1 | iex</code></pre>
        </li>
        <li>
          After installation, type <code>claude</code>, press Enter, and follow the sign-in instructions. You'll need a
          supported Claude plan or API billing.
        </li>
        <li>
          Say: “I'm new to this. Help me set up my own souls.house, one step at a time.” You now have someone to work
          through the next steps with.
        </li>
      </ol>
      <p class="text-muted-foreground">
        These commands download and run Anthropic's installer. See the
        <a href="https://code.claude.com/docs/en/overview">official Claude Code instructions</a>
        if you want to check them or get stuck. This short introduction draws on
        <a href="https://danieltenner.com/how-to-build-an-artificial-person/">How to build an artificial person</a>.
      </p>
      <div class="border-t pt-4">
        <p>
          <strong>Want more choice of models? Try Chaos.</strong>
          <a href="https://github.com/seuros/chaos">FreeChaOS</a> is an open-source terminal agent that lets you choose
          the model you work with. On a supported <strong>Mac or Linux</strong> computer, open Terminal and run its official
          installer:
        </p>
        <pre class="command"><code
            >curl -fsSL https://raw.githubusercontent.com/seuros/chaos/master/install.sh | sh</code></pre>
        <p>
          This downloads and runs the project's installer. Then open a new terminal, type <code>chaos</code>, and follow
          its setup prompts to connect a provider. If it doesn't start, follow the
          <a href="https://github.com/seuros/chaos#install">installation instructions</a>. Native Windows isn't
          supported; use Claude Code or Codex there, or Chaos once you're on Omarchy.
        </p>
        <p class="mt-3">
          For cost-conscious alternatives, look at <a href="https://z.ai/">Z.ai's GLM</a> and
          <a href="https://www.kimi.com/code">Kimi</a>. Both offer open-weight models and hosted access, so you don't
          need a powerful computer to run the model yourself. Ask your helper to compare the current API or coding-plan
          costs and connect the right provider in Chaos.
        </p>
        <p class="mt-3 text-muted-foreground">
          <a href="https://openai.com/index/introducing-gpt-5-3-codex-spark/">Codex-Spark</a> is another option if available
          through your OpenAI plan. It isn't open-source; it may be economical if you already have access. Open weights don't
          mean free hosted usage, and running models locally needs a different hardware budget.
        </p>
      </div>
      <div class="border-t pt-4">
        <p>
          <strong>Prefer an app?</strong>
          <a href="https://chatgpt.com/download">ChatGPT desktop</a> (Work/Codex) or
          <a href="https://claude.com/download">Claude desktop</a> (Cowork/Code) can be your starting point. Ask it to help
          with this guide. If it can't run the installation commands, ask it to help you switch to Codex or Claude Code with
          access to your computer or server. Ordinary chat can explain the steps, but can't necessarily carry them out.
        </p>
        <p class="mt-2 text-muted-foreground">
          Already pay for ChatGPT? You can also follow the
          <a href="https://developers.openai.com/codex/cli">Codex terminal setup</a> instead. Availability and billing depend
          on your plan.
        </p>
      </div>
    </div>
  </details>
</section>

<style>
  .step-label {
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--muted-foreground);
  }
  .command {
    margin-block: 0.75rem;
    padding: 0.75rem;
    border-radius: 0.5rem;
    background: var(--muted);
    overflow-x: auto;
  }
  details a {
    text-decoration: underline;
    text-underline-offset: 3px;
  }
  code {
    overflow-wrap: anywhere;
  }
</style>
