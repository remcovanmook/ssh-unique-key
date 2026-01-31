var identitiesMap = {};
var termHandle = null;
var socket = null;
var fitAddon = null;

// HTML escaping to prevent XSS
function escapeHtml(str) {
    if (!str) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#039;');
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', function () {
    if (window.identitiesList) {
        window.identitiesList.forEach(function (ident) {
            identitiesMap[ident.uuid] = ident;
        });
    }

    // Key Comment Toggle initialization
    var templateSelect = document.getElementById('create_template_select');
    if (templateSelect) {
        toggleKeyComment();
    }

    // Check for Popout Mode
    var params = new URLSearchParams(window.location.search);
    if (params.has('popout')) {
        document.body.classList.add('popout-mode');

        // Hide Detach button
        var btnDetach = document.getElementById('btn-detach');
        if (btnDetach) btnDetach.style.display = 'none';

        var payloadStr = params.get('payload');
        if (payloadStr) {
            try {
                var payload = JSON.parse(payloadStr);
                if (window.xtermEnabled) {
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
function switchView(viewName) {
    document.querySelectorAll('.view-section').forEach(el => el.style.display = 'none');
    document.querySelectorAll('.nav-item').forEach(el => el.classList.remove('active'));
    document.getElementById('view-' + viewName).style.display = 'block';
    document.getElementById('nav-' + viewName).classList.add('active');
    if (viewName === 'templates') fetchTemplates();
    if (viewName === 'history') fetchHistory();
}

// --- User Actions ---
function rotateUserKey(uuid, user) {
    if (!confirm("Rotate key for " + user + "?\n\nThis will:\n1. Generate a new key\n2. Install it on remote\n3. Remove the old key directly.")) return;
    var formData = new FormData();
    formData.append('uuid', uuid);
    formData.append('user', user);
    fetch('/api/user/rotate', { method: 'POST', body: formData })
        .then(response => {
            if (response.ok) {
                alert("Rotation successful!");
                window.location.reload();
            } else {
                response.text().then(t => alert("Error: " + t));
            }
        })
        .catch(e => alert("Network Error: " + e));
}

function deleteUser(uuid, user) {
    if (!confirm("WARNING: Delete user " + user + "?\n\nThis is irreversible. Local keys will be deleted.")) return;
    if (!confirm("Double Check: Really delete " + user + "?")) return;
    var formData = new FormData();
    formData.append('uuid', uuid);
    formData.append('user', user);
    fetch('/api/user/delete', { method: 'POST', body: formData })
        .then(response => {
            if (response.ok) { window.location.reload(); } else { response.text().then(t => alert("Error: " + t)); }
        })
        .catch(e => alert("Network Error: " + e));
}

// --- Templates ---
function fetchTemplates() {
    var el = document.getElementById('templateList');
    el.innerHTML = 'Loading...';
    fetch('/api/templates')
        .then(res => res.json())
        .then(data => {
            if (data.length === 0) { el.innerText = "No templates found."; return; }
            var html = '<table class="table"><thead><tr><th>Name</th><th>Type</th><th>Keys</th><th>Actions</th></tr></thead><tbody>';
            data.forEach(t => {
                var typeLabel = escapeHtml(t.type || 'standard');
                if (t.issuer) typeLabel += ' <small>(' + escapeHtml(t.issuer) + ')</small>';
                var actions = `<button class="btn-red" onclick="deleteTemplate('${escapeHtml(t.name)}')" style="padding:4px 8px;">Delete</button>`;
                html += `<tr><td><strong>${escapeHtml(t.name)}</strong></td><td>${typeLabel}</td><td>${escapeHtml(t.keys.join(', '))}</td><td style="text-align:right;">${actions}</td></tr>`;
            });
            html += '</tbody></table>';
            el.innerHTML = html;
        });
}

function handleTemplateCreate(event) {
    event.preventDefault();
    var name = document.getElementById('tmpl_create_name').value.trim();
    var type = document.getElementById('tmpl_create_type').value;
    if (!name) return false;

    document.getElementById('templateCreateModal').style.display = 'none';

    var formData = new FormData();
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
    return false;
}

function deleteTemplate(name) {
    if (!confirm("Delete template " + name + "?")) return;
    fetch('/api/templates/' + name, { method: 'DELETE' }).then(r => fetchTemplates());
}

// --- History ---
function fetchHistory() {
    var el = document.getElementById('historyList');
    el.innerHTML = '<tr><td colspan="5">Loading...</td></tr>';
    fetch('/api/history')
        .then(res => res.json())
        .then(data => {
            var html = '';
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
function openDeployModal(uuid, user, host) {
    document.getElementById('deploy_uuid').value = uuid;
    document.getElementById('deploy_user_input').value = user;
    document.getElementById('deploy_target_host').value = user + '@' + host;
    document.getElementById('deploy_user').innerText = user + '@' + host;
    document.getElementById('deployModal').style.display = 'block';
}

function openInfoModal(uuid) {
    var data = identitiesMap[uuid];
    if (!data) return;
    document.getElementById('info_uuid').innerText = data.uuid;
    var tbody = document.getElementById('info_host_keys_body');
    tbody.innerHTML = '';
    if (data.host_keys && data.host_keys.length > 0) {
        data.host_keys.forEach(k => {
            tbody.innerHTML += `<tr><td>${escapeHtml(k.type)}</td><td style="font-family:monospace; word-break:break-all;">${escapeHtml(k.key)}</td></tr>`;
        });
    } else { tbody.innerHTML = '<tr><td colspan="2" style="text-align:center;">No keys</td></tr>'; }
    document.getElementById('infoModal').style.display = 'block';
}

function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(function () {
        var x = document.getElementById("toast");
        x.className = "show";
        setTimeout(function () { x.className = x.className.replace("show", ""); }, 3000);
    });
}

function toggleKeyComment() {
    var sel = document.getElementById('create_template_select');
    var div = document.getElementById('create_key_comment_div');
    if (sel && div) {
        if (sel.value === 'none') {
            div.style.display = 'block';
        } else {
            div.style.display = 'none';
        }
    }
}

// --- XTerm Logic ---
var currentCmdPayload = null;

function openTerminal(cmdPayload) {
    // Check if enabled
    if (!window.xtermEnabled) {
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
    var title = "Terminal";
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

    // Init Socket
    socket = io.connect(location.protocol + '//' + document.domain + ':' + location.port);

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
        socket.disconnect(); // Ensure clean cut
    });

    socket.on('session_ended', () => {
        if (document.body.classList.contains('popout-mode')) {
            window.close();
        } else {
            closeTerminal();
        }
    });

    // Resize handler
    window.addEventListener('resize', () => {
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

function closeTerminal() {
    // If in popout mode, strictly close window
    if (document.body.classList.contains('popout-mode')) {
        window.close();
        return;
    }
    document.getElementById('terminalModal').style.display = 'none';
    if (socket) socket.disconnect();
    // Reload page to reflect changes (e.g. if 'create' was run)
    window.location.reload();
}

function detachTerminal() {
    if (!currentCmdPayload) return;

    // Construct URL
    var params = new URLSearchParams();
    params.set('popout', 'true');
    params.set('payload', JSON.stringify(currentCmdPayload));

    var url = window.location.pathname + '?' + params.toString();

    // Open new window
    window.open(url, '_blank', 'width=900,height=700,menubar=no,toolbar=no,location=no,status=no');

    closeTerminal();
}

// --- Connect Logic Override ---
function prepareConnect(uuid, user) {
    var data = identitiesMap[uuid];
    if (!data) return;
    var aliases = data.aliases && data.aliases.length > 0 ? data.aliases : [data.short_uuid];

    if (aliases.length === 1) {
        triggerConnect(user, aliases[0]);
        return;
    }

    // Multiple aliases - show modal
    var container = document.getElementById('connect_aliases_list');
    container.innerHTML = '';
    document.getElementById('connect_user').value = user;
    aliases.forEach((alias, index) => {
        var checked = index === 0 ? 'checked' : '';
        container.innerHTML += `<div style="margin-bottom:8px;"><label style="display:flex;align-items:center;cursor:pointer;"><input type="radio" name="connect_host" value="${escapeHtml(alias)}" ${checked} style="margin-right:8px;"> ${escapeHtml(alias)}</label></div>`;
    });
    document.getElementById('connectModal').style.display = 'block';
}

function triggerConnectSubmit() {
    var user = document.getElementById('connect_user').value;
    var radios = document.getElementsByName('connect_host');
    var host;
    for (var i = 0; i < radios.length; i++) {
        if (radios[i].checked) { host = radios[i].value; break; }
    }
    if (host) {
        triggerConnect(user, host);
        document.getElementById('connectModal').style.display = 'none';
    }
}

function triggerConnect(user, host) {
    if (window.xtermEnabled) {
        openTerminal({ cmd: 'connect', user: user, host: host });
        return;
    }

    // Legacy Fallback
    var formData = new FormData();
    formData.append('user', user);
    formData.append('host', host);
    fetch('/connect', { method: 'POST', body: formData })
        .then(response => {
            if (response.ok) { } else { response.text().then(t => alert("Error: " + t)); }
        })
        .catch(e => alert("Network Error: " + e));
}

// --- Create Logic Override ---
function handleCreateSubmit(event) {
    if (window.xtermEnabled) {
        event.preventDefault();
        document.getElementById('createModal').style.display = 'none';

        var uh = document.getElementById('create_user_host').value;
        var tmpl = document.getElementById('create_template_select').value;
        var kc = document.getElementById('create_key_comment').value;
        var legacy = document.getElementById('create_legacy').checked;

        openTerminal({
            cmd: 'create',
            user_host: uh,
            template: tmpl,
            key_comment: kc,
            legacy: legacy
        });
        return false;
    }
    return true; // proceed with form POST
}

// --- Security Check ---
(function () {
    var h = window.location.hostname;
    if (h !== 'localhost' && h !== '127.0.0.1') {
        var banner = document.getElementById('security-warning');
        if (banner) {
            banner.style.display = 'block';
            banner.innerText += " (Current: " + h + ")";
        }
    }
})();
