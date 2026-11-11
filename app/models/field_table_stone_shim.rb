# The small script put at the top of an interactive stone revision that reads
# Field tables. It gives the authored page `window.field`:
#
#   field.tables          name => { columns, rows, updated_at }, set before the page's own scripts run
#   field.onUpdate(fn)    fn(tables) after each refresh
#   field.refresh()       asks the viewer for fresh rows (at most one fetch per 10 s; extra asks wait)
#   field.ready           a Promise of { canWrite }, once the viewer has answered
#   field.canWrite        true when the stone was opened through its write link
#   field.write(table, row)  appends one row ({ column: value }) to a table this
#                         revision reads; a Promise of the stored row, or an
#                         Error with the house's reason. Rows refresh after.
#
# The first snapshot is embedded (it is the same public data the viewer
# would hand in). Refreshes travel over a MessageChannel this document opens
# before any authored script runs: it sends the viewer one port with the
# token the viewer put in the frame's URL (?k=) and the revision number the
# server actually served here. The viewer binds the first such port for that
# mount and answers only through it, so rows never go to a WindowProxy: a
# document the frame navigates to holds no port and gets nothing, even from a
# refresh already in flight. (The stone's own code can relay rows it holds;
# they are public already.) The page never receives a URL or a credential, and
# its policy keeps connect-src 'none'.
#
# Writes travel the same port. The write key lives only in the viewer (it
# reads it from the link's fragment); the page asks, the viewer sends.
module FieldTableStoneShim

  SCRIPT = <<~JS.freeze
    (() => {
      const listeners = [];
      const token = %<token>s;
      const revision = %<revision>d;
      let current = %<snapshot>s;
      let port = null;
      let canWrite = false;
      let nextId = 1;
      const waiting = new Map();
      let settleReady;
      const ready = new Promise((resolve) => { settleReady = resolve; });
      if (token && window.parent !== window) {
        // A channel owned by this document: the viewer answers only through
        // it, so rows can't reach a document this frame navigates to.
        const channel = new MessageChannel();
        port = channel.port1;
        port.onmessage = (event) => {
          const data = event.data;
          if (!data || data.souls_field !== 1) return;
          if (data.type === "ready") {
            canWrite = data.can_write === true;
            settleReady(Object.freeze({ canWrite }));
            return;
          }
          if (data.type === "written") {
            const entry = waiting.get(data.id);
            if (!entry) return;
            waiting.delete(data.id);
            clearTimeout(entry.timer);
            if (data.ok === true) entry.resolve(data.row);
            else entry.reject(new Error(typeof data.error === "string" ? data.error : "The row was not written"));
            return;
          }
          if (data.type !== "tables") return;
          if (!data.tables || typeof data.tables !== "object" || Array.isArray(data.tables)) return;
          current = data.tables;
          for (const fn of listeners) {
            try { fn(current); } catch (error) { setTimeout(() => { throw error; }); }
          }
        };
        window.parent.postMessage({ souls_field: 1, type: "hello", k: token, revision }, "*", [channel.port2]);
      } else {
        settleReady(Object.freeze({ canWrite: false }));
      }
      const write = (table, row) => new Promise((resolve, reject) => {
        if (!port) return reject(new Error("This page isn't running inside its stone, so it can't write"));
        if (typeof table !== "string" || !row || typeof row !== "object" || Array.isArray(row)) {
          return reject(new Error("field.write(table, row): table is a name, row is an object of column => value"));
        }
        const id = nextId++;
        const timer = setTimeout(() => {
          waiting.delete(id);
          reject(new Error("No answer from the house; the row may or may not have been written"));
        }, 30000);
        waiting.set(id, { resolve, reject, timer });
        port.postMessage({ souls_field: 1, type: "write", id, table, row: JSON.parse(JSON.stringify(row)) });
      });
      const field = Object.freeze({
        get tables() { return current; },
        get canWrite() { return canWrite; },
        ready,
        onUpdate(fn) { if (typeof fn === "function") listeners.push(fn); },
        refresh() { if (port) port.postMessage({ souls_field: 1, type: "refresh" }); },
        write,
      });
      Object.defineProperty(window, "field", { value: field, writable: false, configurable: false });
    })();
  JS

  TOKEN_FORMAT = /\A[A-Za-z0-9_-]{22,64}\z/

  def self.script(revision, token = nil)
    snapshot = ERB::Util.json_escape(revision.field_table_payload.to_json)
    token = nil unless token.is_a?(String) && token.match?(TOKEN_FORMAT)
    format(SCRIPT, snapshot: snapshot, token: ERB::Util.json_escape(token.to_json), revision: revision.number)
  end

  # Puts the script first inside <head> (or straight after the doctype), so it
  # runs before any authored script.
  def self.inject(html, revision, token = nil)
    tag = "<script>#{script(revision, token)}</script>"
    if (match = html.match(/<head(?:\s[^>]*)?>/i))
      html.dup.insert(match.end(0), tag)
    elsif (match = html.match(/<!doctype html[^>]*>/i))
      html.dup.insert(match.end(0), tag)
    else
      tag + html
    end
  end

end
