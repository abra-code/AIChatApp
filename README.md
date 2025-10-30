# AIChatApp
AIChat.app - macOS applet to run large language models locally

AIChat.app allows opening a local GGUF file and start a chat in WebKit view.
It uses llama-server from LLama.cpp project:<br>
https://github.com/ggml-org/llama.cpp/<br>
The app is self-contained with the exception of external GGUF files which can be downloaded from:<br>
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

Binaries excluded from the git repo (need to be added to hydrate the applet):

AIChat.app/Contents/MacOS:<br>
OMCApplet

AIChat.app/Contents/Frameworks:<br>
Abracode.framework

AIChat.app/Contents/Support/Llama.cpp:<br>
llama-server<br>
libggml-base.dylib<br>
libggml-cpu.dylib<br>
libggml-rpc.dylib<br>
libllama.dylib<br>
libggml-blas.dylib<br>
libggml-metal.dylib<br>
libggml.dylib<br>
libmtmd.dylib<br>

Add missing binaries from:<br>
  https://github.com/abra-code/OMC/releases<br>
  https://github.com/ggml-org/llama.cpp/releases<br>
