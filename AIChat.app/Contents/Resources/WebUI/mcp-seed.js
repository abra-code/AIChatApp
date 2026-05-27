// mcp-seed.js — pre-enable bundled MCP servers in the WebUI.
// Runs before bundle.js (plain <script>, not a module) so localStorage is
// already seeded when loadMcpDefaults() executes.
//
// Server IDs are positional: LlamaUI-MCP-Server-N matches the Nth entry in
// llama-ui-mcp.json (1-indexed). Update this list when the bundled server
// set changes and re-run update-mcp-servers.sh.
(function () {
  var k = 'LlamaUi.mcpDefaultEnabled';
  var bundled = [
    { serverId: 'LlamaUI-MCP-Server-1', enabled: true }, // Local (Files & Shell)
    { serverId: 'LlamaUI-MCP-Server-2', enabled: true }, // Time
    { serverId: 'LlamaUI-MCP-Server-3', enabled: true }  // Web Search (DuckDuckGo)
  ];
  try {
    var stored = [];
    try { stored = JSON.parse(localStorage.getItem(k) || '[]'); } catch (e) {}
    if (!Array.isArray(stored)) stored = [];
    var ids = {};
    stored.forEach(function (s) { if (s && s.serverId) ids[s.serverId] = true; });
    bundled.forEach(function (s) { if (!ids[s.serverId]) stored.push(s); });
    localStorage.setItem(k, JSON.stringify(stored));
  } catch (e) {}
}());
