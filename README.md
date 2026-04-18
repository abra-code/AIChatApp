# AIChat.app
![AIChat Icon](Icon/AIChat-macOS-256x256@1x.png)

AIChat.app - macOS applet to run large language models locally

AIChat.app allows opening a local GGUF file and start a chat in WebKit view.  
Version 1.1 adds a **Local Models browser** with model selector dialog, and a **Hugging Face browser** for browsing, downloading, and starting models directly from the app.

The app uses llama-server from LLama.cpp project:<br>
https://github.com/ggml-org/llama.cpp/<br>

AIChat.app is self-contained with the exception of external GGUF files which can be downloaded from:<br>
https://huggingface.co/models<br>
or<br>
https://www.modelscope.cn/models<br>

After the initial setup no network is required to query the LLMs
You can place a chosen GGUF file in applet's Contents/Resources and set AICHAT_MODEL_PATH in aichat.library.sh to make the applet with one model completely self-contained. Then, of course, you need to codesign the modified app.

llama-server comes with its own complete WebUI. The Contents/Resources/WebUI dir contains a slight modification of this UI to display AIChat.png image at landing page.
llama-server is started locally from the app bundle with the following:
```
	webui_dir_path="$OMC_APP_BUNDLE_PATH/Contents/Resources/WebUI"
	"$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" --host 127.0.0.1 --port $port_num --path "$webui_dir_path" --model "$AICHAT_MODEL_PATH" &
```




## Populating and Updating the App Bundle
The instructions below are needed only if you are cloning the repo and not running the pre-built notarized app from distribution archive.  

The app bundle requires binaries that are excluded from git:

### Llama.cpp Distribution (update-llama-cpp.sh)

Use the `update-llama-cpp.sh` script to download and install the latest (or specified) llama.cpp release:

```bash
./update-llama-cpp.sh                           # Auto-detect latest version and host architecture
./update-llama-cpp.sh --version=b8797           # Install specific version
./update-llama-cpp.sh --version=b8797 --arch=arm64  # Specify both version and architecture
```

The script will:
- Download the llama.cpp release from https://github.com/ggml-org/llama.cpp/releases
- Extract and install `llama-server` binary and all required dylibs to `AIChat.app/Contents/Support/Llama.cpp/`
- Update the WebUI (index.html, bundle.js, bundle.css) with AIChat customizations

### Framework and Executable (AppletBuilder.app)

Use OMC's **AppletBuilder.app** to add the framework and executable binary:

- **Abracode.framework** → `AIChat.app/Contents/Frameworks/`
- **AIChat** → `AIChat.app/Contents/MacOS/`

These are managed separately from the llama.cpp distribution and should be added via AppletBuilder.app's workflow.

### Binaries Excluded from Git

AIChat.app/Contents/MacOS:  
AIChat 
  
AIChat.app/Contents/Frameworks:  
Abracode.framework  
  
AIChat.app/Contents/Support/Llama.cpp:  
llama-server  
*.dylib  

Sources:  
  https://github.com/abra-code/OMC/releases (OMCApplet, Abracode.framework)  
  https://github.com/ggml-org/llama.cpp/releases (llama-server, dylibs)  
