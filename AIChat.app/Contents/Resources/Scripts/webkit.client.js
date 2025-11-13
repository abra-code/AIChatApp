// This is an injected client-side JavaScript
// It is associated with OMCWebKitView instance by setting "User Defined Runtime Attributes" in nib control:
// javaScriptFile=webkit.client
// This code is executed by WebKit after HTML document is loaded

// when loading initial HTML there is a <div id="loading">
const loadingDiv = document.getElementById('loading');
if (loadingDiv)
{
	let innerHtml = '<div style="display: block; margin-top: 200px; text-align: center; height: 50vh; align-items: center; justify-content: center;">' +
					'<p><b>Large language model is loading. Please wait...</b></p><progress indeterminate></progress><br><br>' +
					'<p><b>AIChat.app is built with llama-server tool from open source Llama.cpp project</b></p>' +
					'<p><i>The main goal of llama.cpp is to enable LLM inference with minimal setup and state-of-the-art performance on a wide range of hardware - locally and in the cloud.<br>Apple silicon is a first-class citizen - optimized via ARM NEON, Accelerate and Metal frameworks</i></p><br>' +
					'<p><b>AIChat.app is built with OMC engine</b></p>' +
					'<p><i>OnMyCommand is a low code macOS app development environment utilizing command line tools and shell scripts</i></p><br>' +
					'</div>';
	
 	loadingDiv.innerHTML = innerHtml;
}
