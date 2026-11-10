# The small script put at the top of an interactive stone revision that reads
# Field tables. It gives the authored page `window.field`:
#
#   field.tables          name => { columns, rows, updated_at }, set before the page's own scripts run
#   field.onUpdate(fn)    fn(tables) after each refresh
#   field.refresh()       asks the viewer for fresh rows (at most one fetch per 10 s; extra asks wait)
#
# The first snapshot is embedded here (it is the same public data the viewer
# would hand in). Refreshes come only from the trusted viewer by postMessage:
# the shim accepts a message only from window.parent with the expected shape.
# The page never receives a URL or a credential, and its policy keeps
# connect-src 'none'.
module FieldTableStoneShim

  SCRIPT = <<~JS.freeze
    (() => {
      const listeners = [];
      const field = Object.freeze({
        get tables() { return current; },
        onUpdate(fn) { if (typeof fn === "function") listeners.push(fn); },
        refresh() { window.parent.postMessage({ souls_field: 1, type: "refresh" }, "*"); },
      });
      let current = %<snapshot>s;
      Object.defineProperty(window, "field", { value: field, writable: false, configurable: false });
      window.addEventListener("message", (event) => {
        if (event.source !== window.parent) return;
        const data = event.data;
        if (!data || data.souls_field !== 1 || data.type !== "tables") return;
        if (!data.tables || typeof data.tables !== "object" || Array.isArray(data.tables)) return;
        current = data.tables;
        for (const fn of listeners) {
          try { fn(current); } catch (error) { setTimeout(() => { throw error; }); }
        }
      });
    })();
  JS

  def self.script(revision)
    snapshot = ERB::Util.json_escape(revision.field_table_payload.to_json)
    format(SCRIPT, snapshot: snapshot)
  end

  # Puts the script first inside <head> (or straight after the doctype), so it
  # runs before any authored script.
  def self.inject(html, revision)
    tag = "<script>#{script(revision)}</script>"
    if (match = html.match(/<head(?:\s[^>]*)?>/i))
      html.dup.insert(match.end(0), tag)
    elsif (match = html.match(/<!doctype html[^>]*>/i))
      html.dup.insert(match.end(0), tag)
    else
      tag + html
    end
  end

end
