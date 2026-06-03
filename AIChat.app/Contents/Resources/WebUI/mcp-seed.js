// mcp-seed.js — keep the bundled MCP servers present & enabled in the WebUI.
// Runs before bundle.js (plain <script>, not a module) so localStorage is already
// prepared when the store's loadConfig()/loadMcpDefaults() execute.
//
// Two things are seeded, against two independent WebUI localStorage keys:
//
//   1. LlamaUi.mcpDefaultEnabled — per-server enable/disable overrides, keyed by
//      serverId. The bundled servers now carry STABLE ids ("aichat-local",
//      "aichat-time", "aichat-search") assigned via the "id" field in
//      llama-ui-mcp.json by generate_mcp_configs.py — keep the two lists in sync.
//      Stable ids replace the old positional ids (LlamaUI-MCP-Server-N = Nth entry
//      in llama-ui-mcp.json): positions shifted whenever a server was omitted (e.g.
//      network off drops time+search), so a saved enable/disable flag mis-bound to
//      whatever server next landed in that slot. We prune any entry whose serverId
//      is not one of the current bundled ids — this clears stale positional ids and
//      UUIDs accumulated from earlier sessions so they can't shadow the live set —
//      then add any bundled server still missing, defaulting it to enabled. Existing
//      entries for the bundled ids (incl. ones the user disabled) are left alone, so
//      a deliberate disable now persists across launches.
//
//   2. LlamaUi.userOverrides — the set of config keys whose user-edited value
//      shadows the server-provided default. The MCP server *list* itself is the
//      config key "mcpServers", whose default comes from llama-server's
//      --ui-config-file (exposed as props.ui_settings and applied by the store's
//      syncWithServerDefaults()). The moment the user edits the list in the WebUI
//      — including removing a server — "mcpServers" lands in userOverrides and the
//      empty/edited list permanently shadows the config file: the bundled servers
//      never come back. AIChat owns its server list (it is regenerated each launch
//      into llama-ui-mcp.json by the MCP-servers dialog + generate_mcp_configs.py),
//      so we drop "mcpServers" from userOverrides on every load. This makes the
//      list always re-sync from the config file (and pick up the current proxy
//      port), so removing a server in the WebUI hides it only until the next
//      launch. Per-server enable/disable is unaffected — that lives in key (1).
//
// Update the bundled list below when the server set changes and re-run
// update-llama-cpp.sh.
(function () {
  var ENABLED_KEY   = 'LlamaUi.mcpDefaultEnabled';
  var OVERRIDES_KEY = 'LlamaUi.userOverrides';
  // Stable ids — must match the "id" fields written into llama-ui-mcp.json by
  // generate_mcp_configs.py.
  var bundled = [
    { serverId: 'aichat-local',  enabled: true }, // Local (Files & Shell)
    { serverId: 'aichat-time',   enabled: true }, // Time
    { serverId: 'aichat-search', enabled: true }  // Web Search (DuckDuckGo)
  ];

  // (1) Prune stale entries, then seed defaults without clobbering existing choices.
  try {
    var stored = [];
    try { stored = JSON.parse(localStorage.getItem(ENABLED_KEY) || '[]'); } catch (e) {}
    if (!Array.isArray(stored)) stored = [];
    var bundledIds = {};
    bundled.forEach(function (s) { bundledIds[s.serverId] = true; });
    // Drop anything that isn't a current bundled id (old positional ids, UUIDs from
    // prior sessions) so it can't shadow or mis-bind to the live server set.
    stored = stored.filter(function (s) { return s && bundledIds[s.serverId]; });
    // Add any bundled server still missing, defaulting it to enabled. Surviving
    // entries keep the user's enable/disable choice (matched by stable id).
    var present = {};
    stored.forEach(function (s) { present[s.serverId] = true; });
    bundled.forEach(function (s) { if (!present[s.serverId]) stored.push(s); });
    localStorage.setItem(ENABLED_KEY, JSON.stringify(stored));
  } catch (e) {}

  // (2) Let the bundled server list always re-sync from --ui-config-file by
  // clearing the "mcpServers" user override (recovers from removal / port drift).
  try {
    var overrides = [];
    try { overrides = JSON.parse(localStorage.getItem(OVERRIDES_KEY) || '[]'); } catch (e) {}
    if (Array.isArray(overrides) && overrides.indexOf('mcpServers') !== -1) {
      overrides = overrides.filter(function (k) { return k !== 'mcpServers'; });
      localStorage.setItem(OVERRIDES_KEY, JSON.stringify(overrides));
    }
  } catch (e) {}
}());

// === TEMPORARY DIAGNOSTIC PROBE — remove after debugging MCP tool enumeration ===
// Records to localStorage key AICHAT_TOOLDIAG (read off-disk). Captures: boot, MCP/agentic
// console output, each per-server tools/list RESULT (what the WebUI actually enumerates), and
// the tools array sent to the model on /v1/chat/completions. Read-only; passes everything through.
(function () {
  try {
    var KEY = 'AICHAT_TOOLDIAG', MAX = 250;
    function push(rec) {
      try {
        var arr = JSON.parse(localStorage.getItem(KEY) || '[]');
        if (!Array.isArray(arr)) arr = [];
        rec.t = Date.now();
        arr.push(rec);
        if (arr.length > MAX) arr = arr.slice(arr.length - MAX);
        localStorage.setItem(KEY, JSON.stringify(arr));
      } catch (e) {}
    }
    try { localStorage.setItem(KEY, '[]'); } catch (e) {}
    push({ kind: 'boot', probe: 'v2' });

    ['log', 'warn', 'error'].forEach(function (lvl) {
      var orig = console[lvl];
      console[lvl] = function () {
        try {
          var s = Array.prototype.map.call(arguments, function (a) {
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          }).join(' ');
          if (/\[(MCP|Agentic|Tools|MCPService|MCPStore|AgenticStore|ToolsStore)/.test(s))
            push({ kind: 'log', lvl: lvl, msg: s.slice(0, 700) });
        } catch (e) {}
        return orig.apply(console, arguments);
      };
    });

    var of = window.fetch;
    window.fetch = function (input) {
      var url = (typeof input === 'string') ? input : (input && input.url) || '';
      var init = arguments[1];
      var body = init && init.body;
      // tools sent to the model
      try {
        if (/chat\/completions/.test(url) && typeof body === 'string') {
          var j = JSON.parse(body);
          var tn = (j.tools || []).map(function (x) { return x && x.function && x.function.name; });
          push({ kind: 'modelreq', n: tn.length, toolNames: tn });
        }
      } catch (e) {}
      // per-server tools/list result (what the WebUI enumerates)
      var srv = null;
      try {
        var m = url.match(/\/servers\/([^/]+)\/mcp/);
        if (m && typeof body === 'string' && /"method"\s*:\s*"tools\/list"/.test(body)) srv = m[1];
      } catch (e) {}
      var p = of.apply(this, arguments);
      if (srv) {
        try {
          p.then(function (resp) {
            try {
              resp.clone().text().then(function (txt) {
                try {
                  var line = txt.replace(/^data:\s*/gm, '').trim().split('\n').filter(Boolean).pop() || txt;
                  var parsed = null;
                  try { parsed = JSON.parse(line); } catch (e) { try { parsed = JSON.parse(txt); } catch (e2) {} }
                  var names = (parsed && parsed.result && parsed.result.tools)
                    ? parsed.result.tools.map(function (t) { return t.name; }) : null;
                  push({ kind: 'mcplist', server: srv, status: resp.status, n: names ? names.length : -1, toolNames: names });
                } catch (e) {}
              });
            } catch (e) {}
          });
        } catch (e) {}
      }
      return p;
    };
    console.log('[ToolDiag] probe v2 armed');
  } catch (e) {}
}());
