s|Hello there</h1>|AIChat</h1>|
s|("System message",)([A-Za-z]{1,3})="llama-ui"|\1\2="AIChat"|
s|"pointer-events-auto block!"|"pointer-events-auto aichat-flex"|
s|md:text-3xl">AIChat</h1> <p class="text-muted-foreground md:text-lg">|md:text-3xl" style="order:2">AIChat</h1><img src="./AIChat.png" alt="AIChat" class="mb-4" style="width:128px;height:128px;order:1"/><p class="text-muted-foreground md:text-lg" style="order:3">|
# Make the WebUI MCP client's SSE reconnect self-healing. Upstream caps it at
# maxRetries:2 (~2.5s of attempts) then gives up permanently, so any brief stream
# drop (idle model-sleep, WebView App-Nap suspension, a network blip) leaves the
# servers shown as "connected" with 0 tools and the agentic session tool-less, with
# no recovery until a reload. 1e9 = retry for the life of the page (backoff is still
# capped at maxReconnectionDelay:30s, and an aborted page stops scheduling retries).
s|reconnectionDelayGrowFactor:1\.5,maxRetries:2|reconnectionDelayGrowFactor:1.5,maxRetries:1e9|
