// This is an injected client-side JavaScript
// It is associated with OMCWebKitView instance by setting "User Defined Runtime Attributes" in nib control:
// javaScriptFile=webkit.client
// This code is executed by WebKit after HTML document is loaded

function changeBackgroundColor(inColor)
{
	document.body.style.backgroundColor = inColor;
}

changeBackgroundColor("LightGray");

// when loading initial HTML there is a <div id="loading">
const div = document.getElementById('loading');
if (div)
{
	div.innerHTML = '<div style="display: block; margin-top: 200px; text-align: center; height: 300vh; align-items: center; justify-content: center;"><p>Large language model is loading. Please wait...</p><progress indeterminate></progress></div>';
}
