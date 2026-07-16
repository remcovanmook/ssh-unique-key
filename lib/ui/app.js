let identitiesMap = {};
let termHandle = null;
let socket = null;
let fitAddon = null;

/**
 * Reads application bootstrap data from the JSON data island embedded in the
 * HTML by the Jinja2 template (id="app-data", type="application/json").
 *
 * Using a data island instead of inline `globalThis.*` assignments avoids IDE
 * false-positive parse errors caused by Jinja2 double-brace syntax being
 * interpreted as JavaScript object literals.
 *
 * Populates:
 *   - globalThis.identitiesList  {Array}   - list of identity objects from the server
 *   - globalThis.xtermEnabled    {boolean} - whether the xterm terminal is available
 */
function initFromDataIsland() {
    const el = document.getElementById('app-data');
    if (!el) return;
    try {
        const data = JSON.parse(el.textContent);
        globalThis.identitiesList = data.identities || [];
        globalThis.xtermEnabled   = !!data.xtermEnabled;
    } catch (e) {
        console.error('Failed to parse app-data island:', e);
    }
}

/**
 * Escapes HTML special characters to prevent XSS when inserting
 * server-supplied strings into innerHTML.
 *
 * @param {*} str - Value to escape. Non-strings are coerced via String().
 * @returns {string} HTML-safe string.
 */
function escapeHtml(str) {
    if (!str) return '';
    return String(str)
        .replaceAll('&',  '&amp;')
        .replaceAll('<',  '&lt;')
        .replaceAll('>',  '&gt;')
        .replaceAll('"',  '&quot;')
        .replaceAll("'",  '&#039;');
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', function () {
    initFromDataIsland();
    if (globalThis.identitiesList) {
        globalThis.identitiesList.forEach(function (ident) {
            identitiesMap[ident.uuid] = ident;
        });
    }

    // Key Comment Toggle initialization
    const templateSelect = document.getElementById('create_template_select');
    if (templateSelect) {
        toggleKeyComment();
    }

    // Check for Popout Mode
    const params = new URLSearchParams(globalThis.location.search);
    if (params.has('popout')) {
        document.body.classList.add('popout-mode');

        // Hide Detach button
        const btnDetach = document.getElementById('btn-detach');
        if (btnDetach) btnDetach.style.display = 'none';

        const payloadStr = params.get('payload');
        if (payloadStr) {
            try {
                const payload = JSON.parse(payloadStr);
                if (globalThis.xtermEnabled) {
                    setTimeout(() => openTerminal(payload), 100);
                } else {
                    document.body.innerText = "Error: Terminal assets not loaded.";
                }
            } catch (e) {
                console.error("Failed to parse payload", e);
            }
        }
    }
});

// --- Navigation ---

/**
 * Switches the visible view section and marks the corresponding nav item active.
 * Also triggers lazy-loads for 'templates' and 'history' views.
 *
 * @param {string} viewName - One of 'dashboard', 'templates', 'history'.
 */
function switchView(viewName) {
    document.querySelectorAll('.view-section').forEach(el => el.style.display = 'none');
    document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));
    document.getElementById('view-' + viewName).style.display = 'block';
    document.getElementById('nav-' + viewName).classList.add('active');
    if (viewName === 'templates') fetchTemplates();
    if (viewName === 'history') fetchHistory();
}

// --- User Actions ---

/**
 * Sends a key rotation request for a given user on a given identity UUID.
 * Prompts for confirmation before proceeding and reloads on success.
 *
 * @param {string} uuid - UUID of the host identity.
 * @param {string} user - Remote username to rotate the key for.
 */
function rotateUserKey(uuid, user) {
    if (!confirm("Rotate key for " + user + "?\n\nThis will:\n1. Generate a new key\n2. Install it on remote\n3. Remove the old key directly.")) return;
    const formData = new FormData();
    formData.append('uuid', uuid);
    formData.append('user', user);
    fetch('/api/user/rotate', { method: 'POST', body: formData })
        .then(response => {
            if (response.ok) {
                alert("Rotation successful!");
                globalThis.location.reload();
            } else {
                response.text().then(t => alert("Error: " + t));
            }
        })
        .catch(e => alert("Network Error: " + e));
}

/**
 * Deletes a user and their local keys for a given identity UUID.
 * Requires two confirmation prompts before proceeding.
 *
 * @param {string} uuid - UUID of the host identity.
 * @param {string} user - Remote username to delete.
 */
function deleteUser(uuid, user) {
    if (!confirm("WARNING: Delete user " + user + "?\n\nThis is irreversible. Local keys will be deleted.")) return;
    if (!confirm("Double Check: Really delete " + user + "?")) return;
    const formData = new FormData();
    formData.append('uuid', uuid);
    formData.append('user', user);
    fetch('/api/user/delete', { method: 'POST', body: formData })
        .then(response => {
            if (response.ok) {
                globalThis.location.reload();
            } else {
                response.text().then(t => alert("Error: " + t));
            }
        })
        .catch(e => alert("Network Error: " + e));
}

// --- Templates ---

/**
 * Fetches the template list from /api/templates and renders it into
 * the #templateList element as an HTML table.
 */
function fetchTemplates() {
    const el = document.getElementById('templateList');
    el.innerHTML = 'Loading...';
    fetch('/api/templates')
        .then(res => res.json())
        .then(data => {
            if (data.length === 0) { el.innerText = "No templates found."; return; }
            let html = '<table class="table"><thead><tr><th>Name</th><th>Type</th><th>Keys</th><th>Actions</th></tr></thead><tbody>';
            data.forEach(t => {
                let typeLabel = escapeHtml(t.type || 'standard');
                if (t.issuer) typeLabel += ' <small>(' + escapeHtml(t.issuer) + ')</small>';
                const actions = `<button class="btn-red" onclick="deleteTemplate('${escapeHtml(t.name)}')" style="padding:4px 8px;">Delete</button>`;
                html += `<tr><td><strong>${escapeHtml(t.name)}</strong></td><td>${typeLabel}</td><td>${escapeHtml(t.keys.join(', '))}</td><td style="text-align:right;">${actions}</td></tr>`;
            });
            html += '</tbody></table>';
            el.innerHTML = html;
        });
}

/**
 * Handles the template creation form submission. Posts to /api/templates
 * and opens a terminal for sk/opk key types that require interactive generation.
 * Calls event.preventDefault() to suppress native form submission.
 *
 * @param {Event} event - The form submit event.
 */
function handleTemplateCreate(event) {
    event.preventDefault();
    const name = document.getElementById('tmpl_create_name').value.trim();
    const type = document.getElementById('tmpl_create_type').value;
    if (!name) return;

    document.getElementById('templateCreateModal').style.display = 'none';

    const formData = new FormData();
    formData.append('name', name);
    formData.append('type', type);

    fetch('/api/templates', { method: 'POST', body: formData })
        .then(res => {
            if (!res.ok) return res.text().then(t => { throw new Error(t); });
            if (type === 'sk') {
                openTerminal({ cmd: 'template', action: 'generate-sk', name: name });
            } else if (type === 'opk') {
                openTerminal({ cmd: 'template', action: 'generate-opk', name: name });
            } else {
                fetchTemplates();
            }
        })
        .catch(e => alert("Error: " + e.message));

    document.getElementById('tmpl_create_name').value = '';
}

/**
 * Deletes a named template via DELETE /api/templates/:name after confirmation.
 *
 * @param {string} name - Name of the template to delete.
 */
function deleteTemplate(name) {
    if (!confirm("Delete template " + name + "?")) return;
    fetch('/api/templates/' + name, { method: 'DELETE' }).then(() => fetchTemplates());
}

// --- History ---

/**
 * Fetches operation history from /api/history and renders it into
 * the #historyList tbody as table rows.
 */
function fetchHistory() {
    const el = document.getElementById('historyList');
    el.innerHTML = '<tr><td colspan="5">Loading...</td></tr>';
    fetch('/api/history')
        .then(res => res.json())
        .then(data => {
            let html = '';
            if (data.length === 0) html = '<tr><td colspan="5">No history.</td></tr>';
            else {
                data.forEach(e => {
                    html += `<tr><td>${escapeHtml(e.ts.replace('T', ' ').replace('Z', ''))}</td><td>${escapeHtml(e.user)}</td><td><strong>${escapeHtml(e.action)}</strong></td><td>${escapeHtml(e.target)}</td><td>${escapeHtml(e.details)}</td></tr>`;
                });
            }
            el.innerHTML = html;
        });
}

// --- Modals ---

/**
 * Populates and opens the deploy modal for a specific user/host combination.
 *
 * @param {string} uuid - UUID of the host identity.
 * @param {string} user - Remote username to deploy the key for.
 * @param {string} host - Hostname or IP to deploy to.
 */
function openDeployModal(uuid, user, host) {
    document.getElementById('deploy_uuid').value = uuid;
    document.getElementById('deploy_user_input').value = user;
    document.getElementById('deploy_target_host').value = user + '@' + host;
    document.getElementById('deploy_user').innerText = user + '@' + host;
    document.getElementById('deployModal').style.display = 'block';
}

/**
 * Populates and opens the info modal for a given identity UUID,
 * displaying the UUID and any known host keys.
 *
 * @param {string} uuid - UUID of the host identity to show details for.
 */
function openInfoModal(uuid) {
    const data = identitiesMap[uuid];
    if (!data) return;
    document.getElementById('info_uuid').innerText = data.uuid;
    const tbody = document.getElementById('info_host_keys_body');
    tbody.innerHTML = '';
    if (data.host_keys && data.host_keys.length > 0) {
        data.host_keys.forEach(k => {
            tbody.innerHTML += `<tr><td>${escapeHtml(k.type)}</td><td style="font-family:monospace; word-break:break-all;">${escapeHtml(k.key)}</td></tr>`;
        });
    } else {
        tbody.innerHTML = '<tr><td colspan="2" style="text-align:center;">No keys</td></tr>';
    }
    document.getElementById('infoModal').style.display = 'block';
}

/**
 * Copies text to the clipboard and briefly shows a toast notification.
 *
 * @param {string} text - Text to copy.
 */
function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(function () {
        const x = document.getElementById("toast");
        x.className = "show";
        setTimeout(function () { x.className = x.className.replace("show", ""); }, 3000);
    });
}

/**
 * Toggles visibility of the key comment field in the create modal.
 * The field is only relevant when no template is selected (value === 'none').
 */
function toggleKeyComment() {
    const sel = document.getElementById('create_template_select');
    const div = document.getElementById('create_key_comment_div');
    if (sel && div) {
        div.style.display = sel.value === 'none' ? 'block' : 'none';
    }
}

// --- XTerm Logic ---
let currentCmdPayload = null;

/**
 * Opens the terminal modal and initiates a Socket.IO-backed xterm.js session
 * for the given command payload.
 *
 * Requires xterm.js, the FitAddon, and socket.io to be loaded as globals.
 * Cleans up any existing terminal/socket before creating a new one.
 *
 * @param {Object} cmdPayload - Command descriptor. Shape varies by cmd:
 *   { cmd: 'connect', user, host }
 *   { cmd: 'create', user_host, template, key_comment, legacy }
 *   { cmd: 'template', action, name }
 *   All payloads receive a generated term_id if not already set.
 */
function openTerminal(cmdPayload) {
    if (!globalThis.xtermEnabled) {
        alert("Terminal support disabled (backend dependencies missing).");
        return;
    }

    // Generate Session ID if new
    if (!cmdPayload.term_id) {
        cmdPayload.term_id = Math.random().toString(36).substring(2, 15);
    }

    currentCmdPayload = cmdPayload;

    // Show modal
    document.getElementById('terminalModal').style.display = 'block';

    // Set Title
    let title = "Terminal";
    if (cmdPayload.cmd === 'connect') {
        title = "Connect: " + cmdPayload.user + "@" + cmdPayload.host;
    } else if (cmdPayload.cmd === 'create') {
        title = "Create Identity: " + cmdPayload.user_host;
    } else if (cmdPayload.cmd === 'template') {
        title = "Template: " + cmdPayload.action + " " + cmdPayload.name;
    }
    document.getElementById('terminal-title').innerText = title;

    // Cleanup existing
    if (termHandle) {
        termHandle.dispose();
        termHandle = null;
    }
    if (socket) {
        socket.disconnect();
        socket = null;
    }

    document.getElementById('terminal-container').innerHTML = '';

    // Init Socket — location.hostname is preferred over the deprecated document.domain
    socket = io.connect(location.protocol + '//' + location.hostname + ':' + location.port);

    // Init Terminal
    termHandle = new Terminal({
        cursorBlink: true,
        macOptionIsMeta: true,
        scrollback: 1000
    });

    fitAddon = new FitAddon.FitAddon();
    termHandle.loadAddon(fitAddon);

    termHandle.open(document.getElementById('terminal-container'));
    fitAddon.fit();

    // Focus immediately
    setTimeout(() => termHandle.focus(), 100);

    // Update Window Title if in Popout Mode
    if (document.body.classList.contains('popout-mode')) {
        document.title = title;
    }

    // Handle events
    termHandle.onData(data => {
        socket.emit('input', { 'data': data });
    });

    socket.on('connect', () => {
        termHandle.write('\r\nConnected to backend...\r\n');
        socket.emit('connect_terminal', cmdPayload);
    });

    socket.on('output', (msg) => {
        termHandle.write(msg.data);
    });

    socket.on('disconnect_msg', (msg) => {
        termHandle.write('\r\n' + msg.data + '\r\n');
        socket.disconnect();
    });

    socket.on('session_ended', () => {
        if (document.body.classList.contains('popout-mode')) {
            globalThis.close();
        } else {
            closeTerminal();
        }
    });

    // Resize handler
    globalThis.addEventListener('resize', () => {
        if (fitAddon) {
            fitAddon.fit();
            socket.emit('resize', { cols: termHandle.cols, rows: termHandle.rows });
        }
    });

    // Initial resize
    setTimeout(() => {
        fitAddon.fit();
        socket.emit('resize', { cols: termHandle.cols, rows: termHandle.rows });
    }, 300);
}

/**
 * Closes the terminal modal and disconnects the socket.
 * In popout mode, closes the window instead. Reloads the page on close
 * so that any changes made during the session (e.g. new identity) are reflected.
 */
function closeTerminal() {
    if (document.body.classList.contains('popout-mode')) {
        globalThis.close();
        return;
    }
    document.getElementById('terminalModal').style.display = 'none';
    if (socket) socket.disconnect();
    globalThis.location.reload();
}

/**
 * Detaches the current terminal session into a new popup window,
 * passing the command payload as a URL query parameter.
 * Closes the in-page terminal modal after opening the popup.
 */
function detachTerminal() {
    if (!currentCmdPayload) return;

    const params = new URLSearchParams();
    params.set('popout', 'true');
    params.set('payload', JSON.stringify(currentCmdPayload));

    const url = globalThis.location.pathname + '?' + params.toString();
    globalThis.open(url, '_blank', 'width=900,height=700,menubar=no,toolbar=no,location=no,status=no');

    closeTerminal();
}

// --- Connect Logic ---

/**
 * Initiates a connect flow for a given user on a given identity.
 * If the identity has multiple aliases, opens the connect modal so the
 * user can pick which hostname to connect to. If there is only one alias,
 * connects directly.
 *
 * @param {string} uuid - UUID of the host identity.
 * @param {string} user - Remote username to connect as.
 */
function prepareConnect(uuid, user) {
    const data = identitiesMap[uuid];
    if (!data) return;
    const aliases = data.aliases && data.aliases.length > 0 ? data.aliases : [data.short_uuid];

    if (aliases.length === 1) {
        triggerConnect(user, aliases[0]);
        return;
    }

    // Multiple aliases — show picker modal
    const container = document.getElementById('connect_aliases_list');
    container.innerHTML = '';
    document.getElementById('connect_user').value = user;
    aliases.forEach((alias, index) => {
        const checked = index === 0 ? 'checked' : '';
        container.innerHTML += `<div style="margin-bottom:8px;"><label style="display:flex;align-items:center;cursor:pointer;"><input type="radio" name="connect_host" value="${escapeHtml(alias)}" ${checked} style="margin-right:8px;"> ${escapeHtml(alias)}</label></div>`;
    });
    document.getElementById('connectModal').style.display = 'block';
}

/**
 * Reads the selected radio button from the connect modal and calls triggerConnect.
 * Closes the connect modal on success.
 */
function triggerConnectSubmit() {
    const user = document.getElementById('connect_user').value;
    const radios = document.getElementsByName('connect_host');
    let host;
    for (const radio of radios) {
        if (radio.checked) { host = radio.value; break; }
    }
    if (host) {
        triggerConnect(user, host);
        document.getElementById('connectModal').style.display = 'none';
    }
}

/**
 * Triggers a connection to a remote host as a given user.
 * Uses the xterm terminal when available; falls back to a POST to /connect.
 *
 * @param {string} user - Remote username.
 * @param {string} host - Hostname or IP to connect to.
 */
function triggerConnect(user, host) {
    if (globalThis.xtermEnabled) {
        openTerminal({ cmd: 'connect', user: user, host: host });
        return;
    }

    // Legacy Fallback
    const formData = new FormData();
    formData.append('user', user);
    formData.append('host', host);
    fetch('/connect', { method: 'POST', body: formData })
        .then(response => {
            if (!response.ok) { response.text().then(t => alert("Error: " + t)); }
        })
        .catch(e => alert("Network Error: " + e));
}

// --- Create Logic ---

/**
 * Intercepts the "Add New Identity" form submit when xterm is enabled.
 * Extracts form field values and opens an interactive terminal session
 * instead of performing a full-page POST. Falls through to native form
 * submission when xterm is not available.
 *
 * @param {Event} event - The form submit event.
 */
function handleCreateSubmit(event) {
    if (globalThis.xtermEnabled) {
        event.preventDefault();
        document.getElementById('createModal').style.display = 'none';

        const uh     = document.getElementById('create_user_host').value;
        const tmpl   = document.getElementById('create_template_select').value;
        const kc     = document.getElementById('create_key_comment').value;
        const legacy = document.getElementById('create_legacy').checked;

        openTerminal({
            cmd: 'create',
            user_host: uh,
            template: tmpl,
            key_comment: kc,
            legacy: legacy
        });
    }
    // xterm disabled: allow native form POST to proceed
}

// --- Security Check ---
(function () {
    const h = globalThis.location.hostname;
    if (h !== 'localhost' && h !== '127.0.0.1') {
        const banner = document.getElementById('security-warning');
        if (banner) {
            banner.style.display = 'block';
            banner.innerText += " (Current: " + h + ")";
        }
    }
}());
