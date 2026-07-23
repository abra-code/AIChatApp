# Cadabra.app
![Cadabra Icon](Icon/Cadabra-macOS-256x256@1x.png)

Cadabra.app - macOS applet to run large language models locally

This repo holds two applets that share a lineage and a codebase, but not a UI:

| App | Version | Chat UI | Engines |
| --- | --- | --- | --- |
| **Cadabra.app** | 2.0 | native (ActionUI Chat) | **MLX** (mlx-agent) + **GGUF** (llama-server) |
| **AIChat.app** | 1.2 | llama.cpp WebUI in a WebKit view | **GGUF** (llama-server) |

Cadabra.app is the current app. AIChat.app 1.2 is kept as the previous generation and still works,
but the new work happens in Cadabra.

Both apps are self-contained with the exception of external model files, which can be downloaded
from within the app or manually from:<br>
https://huggingface.co/models<br>
or<br>
https://www.modelscope.cn/models<br>

After the initial setup no network is required to query the LLMs.

---

## Cadabra.app (2.0)

One etymology of *abra-cadabra* is "I create as I speak" - the speaking carries over from the
old name.

The chat is **native**: an ActionUI Chat element talking to the model over ACP, not a web view.
There is no bundled WebUI.

**Two engines, picked from the model itself:**

- **MLX** - an Apple-silicon model directory holding `config.json` + `*.safetensors` shards, run by
  the embedded `mlx-agent` (MLX / Metal, arm64 only):<br>
  https://github.com/abra-code/mlx-agent
- **GGUF** - a single `.gguf` file, run by `llama-server` from the llama.cpp project:<br>
  https://github.com/ggml-org/llama.cpp/

Selecting a model is enough - a *file* is treated as GGUF, a *directory* with safetensors shards as
MLX - so both formats sit side by side in the same model list.

**Features**

- Local Models browser with a model selector, RAM-fit advisory, and per-model benchmark
- Hugging Face browser for searching, filtering (Any / MLX / GGUF), downloading, and starting models
- Chat history: named, persisted conversations you can rename, reveal, delete, and continue
- In-place model switching from the chat toolbar, without opening a second window
- **MCP tool support** over stdio, owned by `mlx-agent`, with a servers dialog and an inspector:
  - Time (`mcp-server-time`)
  - Web Search & Fetch (`duckduckgo-mcp-server`)
  - PDF (embedded `pdfutil`, read-only, no network)
  - Local files & shell, sandboxed via `replay`, with explicit read-only and read-write path lists
  - a session-wide **Allow Network** master switch that hard-gates the networked servers

Preferences and state live under `~/Library/Application Support/Cadabra` and the
`com.abracode.Cadabra` preference domains.

---

## AIChat.app (1.2)

The original app: open a local GGUF file and start a chat in a WebKit view.
Version 1.1 added a **Local Models browser** with a model selector dialog, and a **Hugging Face
browser** for browsing, downloading, and starting models directly from the app.

It uses llama-server from the llama.cpp project:<br>
https://github.com/ggml-org/llama.cpp/

llama-server comes with its own complete WebUI. The `Contents/Resources/WebUI` dir contains a slight
modification of this UI to display the AIChat.png image at the landing page.
llama-server is started locally from the app bundle with the following:
```
	webui_dir_path="$OMC_APP_BUNDLE_PATH/Contents/Resources/WebUI"
	"$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" --host 127.0.0.1 --port $port_num --path "$webui_dir_path" --model "$AICHAT_MODEL_PATH" &
```

You can place a chosen GGUF file in the applet's `Contents/Resources` and set `AICHAT_MODEL_PATH` in
`aichat.library.sh` to make the applet with one model completely self-contained. Then, of course,
you need to codesign the modified app.

MCP servers in 1.2 are reached through an HTTP `mcp-proxy` bridge, which is why the V1 bundle keeps
its own Python packages copy. Cadabra dropped the proxy - it speaks stdio directly.

---

## Populating and Updating the App Bundles

The instructions below are needed only if you are cloning the repo and not running a pre-built
notarized app from a distribution archive.

Both app bundles require binaries that are excluded from git.

### Cadabra.app engines (update-cadabra.sh)

`update-cadabra.sh` installs all three runtime engines into `Cadabra.app`, then codesigns the bundle
and verifies the engines actually launch:

```bash
./update-cadabra.sh                              # llama.cpp (latest) + mlx-agent + pdfutil
./update-cadabra.sh --version=b8797              # pin the llama.cpp build tag
./update-cadabra.sh --skip-llama                 # rebuild + redeploy just the agent + pdfutil
./update-cadabra.sh --skip-agent                 # refresh llama.cpp + pdfutil
./update-cadabra.sh --skip-llama --skip-agent    # rebuild + redeploy just pdfutil
```

| Component | Destination | Source |
| --- | --- | --- |
| `llama-server` + dylibs | `Contents/Support/Llama.cpp/` | downloaded GitHub release |
| `mlx-agent` + resource bundles | `Contents/Support/MLX/` | built from source with `xcodebuild` |
| `pdfutil` | `Contents/Support/` | built from source with `./build.sh` |

The agent and pdfutil are built from sibling checkouts (`--agent-repo=` / `--pdfutil-repo=`); the
script offers to `git clone` them if they are missing. No WebUI is downloaded or patched - Cadabra's
chat is native.

**arm64 only for the agent:** mlx-agent is Metal/MLX and does not build for x86_64. The llama.cpp
half still accepts `--arch=x86_64` (pass `--skip-agent` with it). pdfutil builds for either arch.

### Cadabra.app Python MCP servers (update-mcp-servers.py)

```bash
python3 update-mcp-servers.py [--identity=CERT]
```

Installs the Python MCP packages (`mcp-server-time`, `duckduckgo-mcp-server`) into
`Cadabra.app/Contents/Library/Packages` and re-signs. Run once to set up MCP; re-run to add or
upgrade packages.

### AIChat.app llama.cpp distribution (update-llama-cpp.sh)

`update-llama-cpp.sh` serves the V1 app (and Enoch), which renders its UI from llama.cpp's WebUI and
therefore downloads and patches `index.html` / `bundle.js` / `bundle.css` on every update:

```bash
./update-llama-cpp.sh                                # auto-detect latest version and host architecture
./update-llama-cpp.sh --version=b8797                # install specific version
./update-llama-cpp.sh --version=b8797 --arch=arm64   # specify both version and architecture
```

The script will:
- Download the llama.cpp release from https://github.com/ggml-org/llama.cpp/releases
- Extract and install the `llama-server` binary and all required dylibs to
  `AIChat.app/Contents/Support/Llama.cpp/`
- Update the WebUI (index.html, bundle.js, bundle.css) with AIChat customizations

Note: it picks the app bundle by globbing `*.app` in the repo root and taking the first match, which
is `AIChat.app`. Use `update-cadabra.sh` for Cadabra - never this script.

### Framework and executable (AppletBuilder.app)

Use OMC's **AppletBuilder.app** to add the framework and executable binary to either bundle:

- **Abracode.framework** -> `<App>.app/Contents/Frameworks/`
- **Cadabra** -> `Cadabra.app/Contents/MacOS/`
- **AIChat** -> `AIChat.app/Contents/MacOS/`

These are managed separately from the engine distributions and should be added via
AppletBuilder.app's workflow.

### Binaries excluded from git

**Cadabra.app** - only the sources under `Contents/Resources` plus `Info.plist`/`PkgInfo` are
tracked. Excluded:

```
Cadabra.app/Contents/Frameworks     Abracode.framework
Cadabra.app/Contents/MacOS          Cadabra
Cadabra.app/Contents/Library        embedded Python + MCP packages
Cadabra.app/Contents/Support        llama-server + dylibs, mlx-agent, pdfutil, replay
Cadabra.app/Contents/_CodeSignature
```

**AIChat.app** excluded:

```
AIChat.app/Contents/MacOS               AIChat
AIChat.app/Contents/Frameworks          Abracode.framework
AIChat.app/Contents/Support/Llama.cpp   llama-server, *.dylib
AIChat.app/Contents/Support/replay
AIChat.app/Contents/Library/Python
AIChat.app/Contents/Library/Packages
AIChat.app/Contents/Resources/WebUI     bundle.js, bundle.css
AIChat.app/Contents/_CodeSignature
```

Sources:
  https://github.com/abra-code/OMC/releases (OMCApplet, Abracode.framework, replay)
  https://github.com/ggml-org/llama.cpp/releases (llama-server, dylibs)
  https://github.com/abra-code/mlx-agent (mlx-agent)
  https://github.com/abra-code/pdfutil (pdfutil)
