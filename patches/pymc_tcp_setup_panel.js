// =============================================================================
// pymc_usb — pymc_tcp setup helper for the /setup wizard
//
// The pymc_repeater SPA is a precompiled Vue bundle, so we cannot add real
// fields to its setup form. This script does the next best thing:
//
//   1. Watches the wizard's hardware list. The button whose label starts
//      with "pymc_tcp" is detected by name; when it becomes the selected
//      option (Vue adds `border-primary/50` to its class list), we
//      insert a host / port / token block right after the hardware grid,
//      on the same step card. Re-rendering or deselecting hides the
//      block; the user's typed values are preserved across toggles.
//   2. Hooks window.fetch so when the SPA POSTs to /api/setup_wizard with
//      hardware_key="pymc_tcp", the block's values are spliced into the
//      JSON body as pymc_tcp_host / pymc_tcp_port / pymc_tcp_token.
//
// The matching server-side patch (scripts/install.sh §5b) reads those
// fields from the request body and writes them to config.yaml.
// =============================================================================
(function () {
    var FORM_ID = 'pymc_usb-tcp-fields';
    // Match the `name` field of our pymc_tcp entry in radio-settings.json.
    // We accept the legacy "Heltec V3 (Wi-Fi/TCP" label too so a not-yet-
    // re-patched repeater install still surfaces our block.
    var BUTTON_LABEL_MATCHES = ['pymc_tcp', 'Heltec V3 (Wi-Fi/TCP'];
    // The class Vue adds to the actively-selected hardware card.
    var SELECTED_CLASS_MARKER = 'border-primary/50';

    function findTcpButton() {
        var buttons = document.querySelectorAll('button');
        for (var i = 0; i < buttons.length; i++) {
            // textContent includes both the name <div> and the description <div>.
            var txt = buttons[i].textContent;
            for (var k = 0; k < BUTTON_LABEL_MATCHES.length; k++) {
                if (txt.indexOf(BUTTON_LABEL_MATCHES[k]) !== -1) return buttons[i];
            }
        }
        return null;
    }

    function isSelected(btn) {
        return !!(btn && btn.className && btn.className.indexOf(SELECTED_CLASS_MARKER) !== -1);
    }

    function buildBlock() {
        var d = document.createElement('div');
        d.id = FORM_ID;
        d.style.cssText =
            'margin-top:14px;padding:14px 16px;border:1px solid rgba(46,125,87,.6);' +
            'background:rgba(46,125,87,.06);border-radius:12px;color:inherit;' +
            'font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;';
        d.innerHTML =
            '<strong style="display:block;margin-bottom:6px;color:#2e7d57;">' +
            'pymc_tcp — connection details</strong>' +
            '<div style="font-size:12px;opacity:.75;margin-bottom:10px;">' +
            'Provision the Heltec on Wi-Fi first (AP portal at 192.168.4.1), ' +
            'then enter its LAN address here. The token is optional ' +
            '— leave it empty if the modem accepts open connections.' +
            '</div>' +
            '<label style="display:block;font-weight:600;margin:8px 0 4px;">Host</label>' +
            '<input id="' + FORM_ID + '-host" type="text" autocomplete="off" ' +
            'placeholder="heltec-abcdef.local or 192.168.1.50" ' +
            'style="width:100%;padding:8px 10px;box-sizing:border-box;' +
            'border:1px solid #bbb;border-radius:6px;font:inherit;color:inherit;background:rgba(255,255,255,.65);">' +
            '<label style="display:block;font-weight:600;margin:10px 0 4px;">Port</label>' +
            '<input id="' + FORM_ID + '-port" type="number" min="1" max="65535" value="5055" ' +
            'style="width:100%;padding:8px 10px;box-sizing:border-box;' +
            'border:1px solid #bbb;border-radius:6px;font:inherit;color:inherit;background:rgba(255,255,255,.65);">' +
            '<label style="display:block;font-weight:600;margin:10px 0 4px;">' +
            'Token <span style="opacity:.6;font-weight:400;">(optional)</span></label>' +
            '<input id="' + FORM_ID + '-token" type="password" autocomplete="new-password" ' +
            'placeholder="leave empty for open LAN" ' +
            'style="width:100%;padding:8px 10px;box-sizing:border-box;' +
            'border:1px solid #bbb;border-radius:6px;font:inherit;color:inherit;background:rgba(255,255,255,.65);">';
        return d;
    }

    function ensureBlockAfterGrid(btn) {
        var existing = document.getElementById(FORM_ID);
        if (existing) return existing;
        var grid = btn.parentElement;
        if (!grid || !grid.parentElement) return null;
        var block = buildBlock();
        // Insert as a sibling immediately after the grid so the form
        // shares the step card's vertical flow but stays out of the
        // grid layout itself.
        grid.parentElement.insertBefore(block, grid.nextSibling);
        return block;
    }

    function syncBlock() {
        var btn = findTcpButton();
        var block = document.getElementById(FORM_ID);
        if (!btn) {
            // Wizard not on the hardware step (or DOM not ready yet) —
            // keep any existing block hidden so values aren't lost when
            // the user navigates back and forth.
            if (block) block.style.display = 'none';
            return;
        }
        if (isSelected(btn)) {
            block = block || ensureBlockAfterGrid(btn);
            if (block) block.style.display = '';
        } else if (block) {
            block.style.display = 'none';
        }
    }

    // Coalesce mutations: many class flips happen in one tick when Vue
    // re-renders, but we only need one syncBlock per animation frame.
    var pending = false;
    function scheduleSync() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () { pending = false; syncBlock(); });
    }

    var observer = new MutationObserver(scheduleSync);
    observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['class'],
    });

    // Route changes — Vue Router uses pushState/replaceState.
    ['pushState', 'replaceState'].forEach(function (m) {
        var orig = history[m];
        history[m] = function () {
            var rv = orig.apply(this, arguments);
            scheduleSync();
            return rv;
        };
    });
    window.addEventListener('popstate', scheduleSync);
    window.addEventListener('DOMContentLoaded', scheduleSync);
    scheduleSync();

    // Splice values into the wizard's POST body. Only mutates the request
    // when pymc_tcp (or its legacy alias tcp_heltec) is the selected
    // hardware; other selections pass through untouched.
    var origFetch = window.fetch;
    var TCP_KEYS = ['pymc_tcp', 'tcp_heltec'];
    window.fetch = function (input, init) {
        try {
            var url = (typeof input === 'string') ? input : (input && input.url);
            var method = (init && init.method) || (input && input.method) || 'GET';
            if (
                url &&
                url.indexOf('/api/setup_wizard') !== -1 &&
                method.toUpperCase() === 'POST' &&
                init && typeof init.body === 'string'
            ) {
                var body = JSON.parse(init.body);
                if (body && TCP_KEYS.indexOf(body.hardware_key) !== -1) {
                    var hostEl = document.getElementById(FORM_ID + '-host');
                    var portEl = document.getElementById(FORM_ID + '-port');
                    var tokenEl = document.getElementById(FORM_ID + '-token');
                    var host = hostEl ? hostEl.value.trim() : '';
                    var portStr = portEl ? portEl.value.trim() : '';
                    var token = tokenEl ? tokenEl.value : '';
                    if (host) body.pymc_tcp_host = host;
                    if (portStr) {
                        var port = parseInt(portStr, 10);
                        if (!isNaN(port)) body.pymc_tcp_port = port;
                    }
                    if (token !== '') body.pymc_tcp_token = token;
                    init.body = JSON.stringify(body);
                }
            }
        } catch (e) {
            // Never let a hook error block the real wizard request.
        }
        return origFetch.apply(this, arguments);
    };
})();
