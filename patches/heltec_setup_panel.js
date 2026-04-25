// =============================================================================
// pymc_usb — Heltec TCP setup helper for the /setup wizard
//
// The pymc_repeater SPA is a pre-compiled Vue bundle, so we can't add real
// fields to its setup form. Instead this script:
//   1. Renders a floating panel (host / port / token) only while the user is
//      on the /setup route.
//   2. Hooks window.fetch so when the SPA POSTs to /api/setup_wizard with
//      hardware_key="tcp_heltec", we splice the panel's values into the
//      JSON body as tcp_heltec_host / tcp_heltec_port / tcp_heltec_token.
//
// The matching server-side patch (scripts/install.sh §5b) reads those
// fields from the request body and writes them to config.yaml.
// =============================================================================
(function () {
    var PANEL_ID = 'pymc_usb-tcp-setup-panel';
    var SETUP_PATHS = ['/setup', '/wizard', '/initial-setup'];

    function isSetupRoute() {
        var p = location.pathname.replace(/\/+$/, '');
        for (var i = 0; i < SETUP_PATHS.length; i++) {
            if (p === SETUP_PATHS[i] || p.endsWith(SETUP_PATHS[i])) return true;
        }
        return false;
    }

    function buildPanel() {
        if (document.getElementById(PANEL_ID)) return;
        var div = document.createElement('div');
        div.id = PANEL_ID;
        div.style.cssText =
            'position:fixed;top:14px;right:14px;z-index:99998;' +
            'background:#fff;border:1px solid #2e7d57;border-radius:6px;padding:14px;' +
            'box-shadow:0 4px 12px rgba(0,0,0,.18);width:300px;color:#222;' +
            'font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;';
        div.innerHTML =
            '<strong style="display:block;margin-bottom:6px;color:#2e7d57;">' +
            'Heltec TCP modem</strong>' +
            '<div style="font-size:11px;color:#666;margin-bottom:8px;">' +
            'Only used if you pick <em>Heltec V3 (Wi-Fi/TCP modem)</em> in the ' +
            'hardware list. These values are saved when you finish the wizard.' +
            '</div>' +
            '<label style="display:block;margin:6px 0 2px;font-weight:600;">Host</label>' +
            '<input id="' + PANEL_ID + '-host" type="text" autocomplete="off" ' +
            'placeholder="heltec-abcdef.local or 192.168.1.50" ' +
            'style="width:100%;padding:6px;box-sizing:border-box;border:1px solid #bbb;border-radius:4px;font:inherit;">' +
            '<label style="display:block;margin:6px 0 2px;font-weight:600;">Port</label>' +
            '<input id="' + PANEL_ID + '-port" type="number" min="1" max="65535" value="5055" ' +
            'style="width:100%;padding:6px;box-sizing:border-box;border:1px solid #bbb;border-radius:4px;font:inherit;">' +
            '<label style="display:block;margin:6px 0 2px;font-weight:600;">Token ' +
            '<span style="color:#888;font-weight:400;">(optional)</span></label>' +
            '<input id="' + PANEL_ID + '-token" type="password" autocomplete="new-password" ' +
            'placeholder="leave empty for open LAN" ' +
            'style="width:100%;padding:6px;box-sizing:border-box;border:1px solid #bbb;border-radius:4px;font:inherit;">';
        document.body.appendChild(div);
    }

    function destroyPanel() {
        var el = document.getElementById(PANEL_ID);
        if (el) el.remove();
    }

    function syncVisibility() {
        if (isSetupRoute()) buildPanel();
        else destroyPanel();
    }

    // The Vue SPA uses HTML5 history.pushState / replaceState; intercept both
    // so route changes trigger a re-check of our panel visibility.
    ['pushState', 'replaceState'].forEach(function (m) {
        var orig = history[m];
        history[m] = function () {
            var rv = orig.apply(this, arguments);
            setTimeout(syncVisibility, 0);
            return rv;
        };
    });
    window.addEventListener('popstate', syncVisibility);
    window.addEventListener('DOMContentLoaded', syncVisibility);
    // Initial render in case DOMContentLoaded already fired.
    setTimeout(syncVisibility, 50);

    // Splice panel values into the wizard's POST body. Only mutates the
    // request when the user actually picked tcp_heltec; other hardware
    // selections pass through untouched.
    var origFetch = window.fetch;
    window.fetch = function (input, init) {
        try {
            var url = (typeof input === 'string') ? input : (input && input.url);
            var method = (init && init.method ? init.method : (input && input.method)) || 'GET';
            if (
                url &&
                url.indexOf('/api/setup_wizard') !== -1 &&
                method.toUpperCase() === 'POST' &&
                init && typeof init.body === 'string'
            ) {
                var body = JSON.parse(init.body);
                if (body && body.hardware_key === 'tcp_heltec') {
                    var hostEl = document.getElementById(PANEL_ID + '-host');
                    var portEl = document.getElementById(PANEL_ID + '-port');
                    var tokenEl = document.getElementById(PANEL_ID + '-token');
                    var host = hostEl ? hostEl.value.trim() : '';
                    var portStr = portEl ? portEl.value.trim() : '';
                    var token = tokenEl ? tokenEl.value : '';
                    if (host) body.tcp_heltec_host = host;
                    if (portStr) {
                        var port = parseInt(portStr, 10);
                        if (!isNaN(port)) body.tcp_heltec_port = port;
                    }
                    // Only forward token when the user actually typed one;
                    // an empty input means "no auth", which the server
                    // already defaults to.
                    if (token !== '') body.tcp_heltec_token = token;
                    init.body = JSON.stringify(body);
                }
            }
        } catch (e) {
            // Never let a hook error block the real wizard request.
        }
        return origFetch.apply(this, arguments);
    };
})();
