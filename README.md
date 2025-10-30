# AIChatApp
AIChat.app - macOS applet to run large language models locally

AIChat.app allows opening a local GGUF file and start a chat in WebKit view.
It uses llama-server from LLama.cpp project:
https://github.com/ggml-org/llama.cpp/
The app is self-contained with the exception of external GGUF files which can be downloaded from:
  https://huggingface.co/models
or
  https://www.modelscope.cn/models

After the initial setup no network is required to query the LLMs
You can place a chosen GGUF file in applet's Contents/Resources and set AICHAT_MODEL_PATH in aichat.library.sh to make the applet with one model completely self-contained. Then, of course, you need to codesign the modified app.

llama-server comes with its own complete WebUI. The Contents/Resources/WebUI dir contains a slight modification of this UI to display AIChat.png image at landing page.
llama-server is started locally from the app bundle with the following:
```
	webui_dir_path="$OMC_APP_BUNDLE_PATH/Contents/Resources/WebUI"
	"$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server" --host 127.0.0.1 --port $port_num --path "$webui_dir_path" --model "$AICHAT_MODEL_PATH" &
```

Binaries excluded from the git repo (need to be added to hydrate the applet):

AIChat.app/Contents/MacOS:
  OMCApplet

AIChat.app/Contents/Frameworks:
  Abracode.framework

AIChat.app/Contents/Support/Llama.cpp:
  libggml-base.dylib	libggml-cpu.dylib	libggml-rpc.dylib	libllama.dylib		llama-server
  libggml-blas.dylib	libggml-metal.dylib	libggml.dylib		libmtmd.dylib

Add missing binaries from:
  https://github.com/abra-code/OMC/releases
  https://github.com/ggml-org/llama.cpp/releases
