#!/usr/bin/env python3
# Monkey patch early if possible
try:
    from gevent import monkey
    monkey.patch_all()
except ImportError:
    pass

import sys
import os
import secrets
import threading
import webbrowser
import subprocess
import signal
import logging
import tempfile
import stat
import json
import fcntl
import struct
import shutil
import time
import shutil
import time
import select
import argparse
import socket

try:
    import pty
    import termios
except ImportError:
    # Windows compatibility (unlikely for this specific app but good practice)
    pty = None
    termios = None

from flask import Flask, session, request, render_template, abort, redirect, url_for, jsonify, send_from_directory, Response

# Optional: Flask-SocketIO and Eventlet
try:
    from flask_socketio import SocketIO, emit, disconnect
    import gevent
    SOCKETIO_AVAILABLE = True
except ImportError:
    SOCKETIO_AVAILABLE = False
    SocketIO = None

# Application Configuration
HOST = '127.0.0.1'
PORT = 8080
SECRET_KEY = secrets.token_hex(32)
AUTH_TOKEN = secrets.token_urlsafe(32)

# SSH Key Management Paths
HOME_DIR = os.path.expanduser("~")
BASE_DIR = os.path.join(HOME_DIR, ".ssh", "unique_keys")
HOST_DIR = os.path.join(BASE_DIR, "by-host")
UUID_DIR = os.path.join(BASE_DIR, "host-uuid")
KEY_DIR = os.path.join(BASE_DIR, "by-key")
SSH_TEMPLATE_DIR = os.path.join(BASE_DIR, "templates")
LOG_FILE = os.path.join(BASE_DIR, "history.log")

# Setup Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger('ssh-ui')

# Determine absolute paths
LIB_DIR = os.path.dirname(os.path.realpath(__file__))
BASE_REPO_DIR = os.path.dirname(LIB_DIR)
BIN_DIR = os.path.join(BASE_REPO_DIR, 'bin')

# UI assets live alongside this script in lib/ui
UI_DIR = os.path.join(LIB_DIR, 'ui')
# Existing static dir for legacy static assets
LEGACY_STATIC_DIR = os.path.join(UI_DIR, 'static')

# Initialize Flask
# We set static_folder to UI_DIR so we can serve /xterm/... and /static/...
app = Flask(__name__, template_folder=UI_DIR, static_folder=UI_DIR, static_url_path='/assets')
app.secret_key = SECRET_KEY

# Initialize SocketIO if available
socketio = None
if SOCKETIO_AVAILABLE:
    # CORS origins will be set at startup once port is known
    socketio = SocketIO(app, async_mode='gevent', cors_allowed_origins=[])

# Global map for active PTYs: sid -> {fd, pid, ...}
# Global map for active PTYs: term_id -> {fd, pid, sid, timer}
active_terminals = {}
# Map sid -> term_id for quick lookup
sid_to_term = {}

# --- Helper: serve static files explicitly if needed or rely on Flask ---
@app.route('/static/<path:filename>')
def custom_static(filename):
    """Serve legacy static files from lib/ui/static if needed."""
    return send_from_directory(LEGACY_STATIC_DIR, filename)

# --- Browser Defaults ---
@app.route('/favicon.ico')
def favicon():
    # Simple SVG Key Icon
    svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <text y=".9em" font-size="90">🔑</text>
    </svg>'''
    return Response(svg, mimetype='image/svg+xml')

@app.route('/robots.txt')
def robots():
    return Response("User-agent: *\nDisallow: /", mimetype='text/plain')
def get_identities():
    identities = {}
    if os.path.exists(UUID_DIR):
        for uuid in os.listdir(UUID_DIR):
            uuid_path = os.path.join(UUID_DIR, uuid)
            if not os.path.isdir(uuid_path): continue
            
            users = []
            host_keys = []
            
            # --- Host Keys ---
            kh_path = os.path.join(uuid_path, "known_host_keys")
            if os.path.exists(kh_path):
                try:
                    with open(kh_path, 'r') as f:
                        for line in f:
                            line = line.strip()
                            if not line or line.startswith('#'): continue
                            parts = line.split()
                            ktype = "unknown"
                            key_content = ""
                            for i, p in enumerate(parts):
                                if p.startswith('ssh-') or p.startswith('ecdsa-'):
                                    ktype = p
                                    if i+1 < len(parts): key_content = parts[i+1]
                                    break
                            clean_type = ktype.replace('ssh-', '').replace('ecdsa-sha2-', '')
                            import hashlib
                            key_hash = hashlib.md5(line.encode('utf-8')).hexdigest()
                            host_keys.append({'type': clean_type, 'full_type': ktype, 'key': key_content, 'id': key_hash})
                except Exception: pass

            # --- Users ---
            for item in os.listdir(uuid_path):
                if item == uuid: continue
                item_path = os.path.join(uuid_path, item)
                if os.path.islink(item_path): continue
                if os.path.isdir(item_path):
                    user_keys = []
                    pub_path = os.path.join(item_path, "identity.pub")
                    is_template = False
                    template_name = ""
                    
                    priv_path = os.path.join(item_path, "identity")
                    if os.path.islink(priv_path):
                        try:
                            target = os.readlink(priv_path)
                            if "templates/" in target:
                                parts = target.split('/')
                                if "templates" in parts:
                                    template_name = parts[parts.index("templates")+1]
                                    is_template = True
                        except OSError: pass

                    if os.path.exists(pub_path):
                        try:
                            with open(pub_path, 'r') as f:
                                raw = f.read().strip()
                                parts = raw.split()
                                if parts:
                                    kt = parts[0]
                                    ct = kt.replace('ssh-', '').replace('ecdsa-sha2-', '')
                                    user_keys.append({'type': ct, 'content': raw})
                        except Exception: pass
                    
                    users.append({'name': item, 'ssh_keys': user_keys, 'is_template': is_template, 'template_name': template_name})
            
            users.sort(key=lambda x: x['name'])
            identities[uuid] = {'uuid': uuid, 'short_uuid': uuid[:8], 'users': users, 'aliases': [], 'host_keys': host_keys}

    if os.path.exists(HOST_DIR):
        for host in os.listdir(HOST_DIR):
            host_path = os.path.join(HOST_DIR, host)
            if os.path.islink(host_path):
                try:
                    target = os.readlink(host_path)
                    target_abs = os.path.abspath(os.path.join(HOST_DIR, target))
                    cur_uuid = os.path.basename(target_abs)
                    if cur_uuid in identities:
                        identities[cur_uuid]['aliases'].append(host)
                except OSError: pass
    
    results = list(identities.values())
    results.sort(key=lambda x: x['aliases'][0] if x['aliases'] else x['uuid'])
    return results

def get_templates_list():
    templates = []
    if os.path.exists(SSH_TEMPLATE_DIR):
        for item in os.listdir(SSH_TEMPLATE_DIR):
            item_path = os.path.join(SSH_TEMPLATE_DIR, item)
            if os.path.isdir(item_path):
                keys = []
                for f in os.listdir(item_path):
                    if f.startswith('id_') and f.endswith('.pub'):
                        keys.append(f.replace('.pub', '').replace('id_', ''))
                tmpl = {'name': item, 'keys': keys}
                type_file = os.path.join(item_path, '.type')
                issuer_file = os.path.join(item_path, '.issuer')
                if os.path.isfile(type_file):
                    with open(type_file) as f: tmpl['type'] = f.read().strip()
                if os.path.isfile(issuer_file):
                    with open(issuer_file) as f: tmpl['issuer'] = f.read().strip()
                if any(k.endswith('_sk') for k in keys):
                    tmpl['type'] = 'sk'
                templates.append(tmpl)
    templates.sort(key=lambda x: x['name'])
    return templates

def check_auth():
    """Check auth via HTTP-only cookie, or session fallback."""
    token = request.cookies.get('auth_token') or session.get('auth_token')
    return token == AUTH_TOKEN

@app.before_request
def before_request():
    if request.endpoint == 'static' or request.endpoint == 'custom_static': return
    if request.endpoint == 'favicon' or request.endpoint == 'robots': return
    # If token is in URL query param, set HTTP-only cookie and redirect to strip it
    url_token = request.args.get('token')
    if url_token == AUTH_TOKEN:
        # Build clean URL without the token param
        from urllib.parse import urlencode, parse_qs, urlparse, urlunparse
        parsed = urlparse(request.url)
        params = parse_qs(parsed.query, keep_blank_values=True)
        params.pop('token', None)
        clean_query = urlencode(params, doseq=True)
        clean_url = urlunparse(parsed._replace(query=clean_query))
        resp = redirect(clean_url)
        resp.set_cookie('auth_token', AUTH_TOKEN, httponly=True, samesite='Strict', path='/')
        return resp
    if not check_auth(): return "Unauthorized: Missing or invalid token", 401

@app.route('/')
def index():
    identities = get_identities()
    result_output = session.pop('last_output', None)
    result_status = session.pop('last_status', None)
    templates = get_templates_list()
    
    return render_template('index.html',
                           identities=identities,
                           templates=templates,
                           result_output=result_output,
                           result_status=result_status,
                           xterm_enabled=SOCKETIO_AVAILABLE)

# --- Legacy Terminal Launch (External) ---
def launch_terminal_script(script_content, base_name):
    """Launch external terminal (fallback)."""
    tmp_dir = os.path.join(BASE_DIR, "tmp")
    os.makedirs(tmp_dir, exist_ok=True)
    unique_id = secrets.token_hex(4)
    
    if sys.platform == 'darwin':
        filename = f"{base_name}_{unique_id}.command"
        path = os.path.join(tmp_dir, filename)
        with open(path, 'w') as f:
            f.write(script_content + f"\nrm -- '{path}'\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        subprocess.run(['open', path], check=True)
        return "Launched macOS Terminal"
    elif sys.platform.startswith('linux'):
        filename = f"{base_name}_{unique_id}.sh"
        path = os.path.join(tmp_dir, filename)
        with open(path, 'w') as f:
            f.write(script_content + f"\nrm -- '{path}'\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        
        terminals = [('x-terminal-emulator', ['-e']), ('gnome-terminal', ['--']), ('konsole', ['-e']), ('xfce4-terminal', ['-x']), ('xterm', ['-e'])]
        launched = False
        last_err = None
        for term, args in terminals:
            if shutil.which(term):
                try:
                    subprocess.Popen([term] + args + [path])
                    launched = True
                    break
                except Exception as e: last_err = e
        if not launched: raise Exception(f"No terminal found. {last_err}")
        return f"Launched Linux Terminal ({term})"
    else:
        raise Exception(f"Unsupported platform: {sys.platform}")

# --- Routes for Actions ---

@app.route('/create', methods=['POST'])
def create_identity():
    if not check_auth(): return redirect(url_for('login'))
    user_host = request.form.get('user_host')
    template = request.form.get('template')
    key_comment = request.form.get('key_comment')
    
    if not user_host: return "Invalid input.", 400
    import re
    if not re.match(r'^[a-zA-Z0-9.\-_@]+$', user_host): return "Security block: Invalid characters.", 400
    if template and not re.match(r'^[a-zA-Z0-9.\-_]+$', template): return "Security block: Invalid template.", 400
    if key_comment and not re.match(r'^[a-zA-Z0-9.\-_@ ]+$', key_comment): return "Security block: Invalid comment.", 400
    
    legacy = request.form.get('legacy')
    ssh_new_path = os.path.join(BIN_DIR, "ssh-new")
    args = []
    if legacy: args.append("--legacy")
    if template and template.lower() != 'none': args.append(f"--template '{template}'")
    if key_comment: args.append(f"--key-comment '{key_comment}'")
    args.append(f"'{user_host}'")
    
    script_content = "#!/bin/bash\n" + f"'{ssh_new_path}' {' '.join(args)}\n"
    safe_host = "".join([c for c in user_host if c.isalnum() or c in ('-', '_', '.', '@')])
    
    try:
        launch_terminal_script(script_content, f"create_{safe_host}")
        session['last_status'] = 'info'
        session['last_output'] = f"Launched Terminal for: {user_host}..."
        return redirect(url_for('index'))
    except Exception as e: return f"Launch error: {str(e)}", 500

@app.route('/connect', methods=['POST'])
def connect_host():
    if not check_auth(): return "Unauthorized", 401
    user = request.form.get('user')
    host = request.form.get('host')
    if not user or not host: return "Missing argument", 400
    safe_user = "".join([c for c in user if c.isalnum() or c in ('-', '_', '.')])
    safe_host = "".join([c for c in host if c.isalnum() or c in ('-', '_', '.', '@')])
    target = f"{safe_user}@{safe_host}"
    
    script_content = "#!/bin/bash\n" + f"echo 'Connecting to {target}...'\nssh '{target}'\n"
    
    try:
        launch_terminal_script(script_content, f"connect_{safe_user}_{safe_host}")
        return "Launched", 200
    except Exception as e: return f"Launch error: {str(e)}", 500

@app.route('/deploy', methods=['POST'])
def deploy_key():
    uuid = request.form.get('uuid')
    user = request.form.get('user')
    target_host = request.form.get('target_host')
    password = request.form.get('password')
    if not all([uuid, user, target_host, password]): return "Missing fields", 400
    
    import re
    safe_uuid = os.path.basename(uuid)
    safe_user = os.path.basename(user)
    # Validate target_host to prevent command injection
    if not re.match(r'^[a-zA-Z0-9.\-_@:]+$', target_host):
        return "Security block: Invalid target host characters.", 400
    identity_pub_path = os.path.join(UUID_DIR, safe_uuid, safe_user, "identity.pub")
    if not os.path.exists(identity_pub_path): return "Identity not found", 404

    try:
        # Escape single quotes in password to prevent shell injection
        safe_password = password.replace("'", "'\\''")
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as tf:
            tf.write(f"#!/bin/sh\necho '{safe_password}'\n")
            askpass_path = tf.name
        os.chmod(askpass_path, 0o700)
        
        env = os.environ.copy()
        env['SSH_ASKPASS'] = askpass_path
        env['SSH_ASKPASS_REQUIRE'] = 'force'
        env['DISPLAY'] = 'dummy:0'
        
        cmd = ['ssh-copy-id', '-i', identity_pub_path, '-o', 'StrictHostKeyChecking=accept-new', f"{safe_user}@{target_host}"]
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        os.unlink(askpass_path)
        
        session['last_output'] = result.stderr + "\n" + result.stdout
        session['last_status'] = 'success' if result.returncode == 0 else 'error'
        return redirect(url_for('index'))
    except Exception as e:
        if 'askpass_path' in locals() and os.path.exists(askpass_path): os.unlink(askpass_path)
        return f"Error: {e}", 500

@app.route('/api/user/rotate', methods=['POST'])
def rotate_user_key():
    if not check_auth(): return "Unauthorized", 401
    uuid = request.form.get('uuid')
    user = request.form.get('user')
    if not uuid or not user: return "Missing fields", 400
    safe_uuid = os.path.basename(uuid)
    safe_user = os.path.basename(user)
    cmd = [os.path.join(BIN_DIR, "ssh-user-rotate"), safe_uuid, safe_user]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        session['last_output'] = result.stderr + "\n" + result.stdout
        session['last_status'] = 'success' if result.returncode == 0 else 'error'
        if result.returncode != 0: return f"Failed: {result.stderr}", 500
        return "Rotated", 200
    except Exception as e: return f"Error: {e}", 500

@app.route('/api/user/delete', methods=['POST'])
def delete_user():
    if not check_auth(): return "Unauthorized", 401
    uuid = request.form.get('uuid')
    user = request.form.get('user')
    if not uuid or not user: return "Missing fields", 400
    safe_uuid = os.path.basename(uuid)
    safe_user = os.path.basename(user)
    user_path = os.path.join(UUID_DIR, safe_uuid, safe_user)
    if not os.path.exists(user_path): return "Not found", 404
    
    try:
        shutil.rmtree(user_path)
        # Cleanup logic (collapsed for brevity, same as before)
        uuid_dir = os.path.dirname(user_path)
        if not any(os.path.isdir(os.path.join(uuid_dir, i)) for i in os.listdir(uuid_dir)):
            shutil.rmtree(uuid_dir)
            if os.path.exists(HOST_DIR):
                for f in os.listdir(HOST_DIR):
                    p = os.path.join(HOST_DIR, f)
                    if os.path.islink(p) and os.path.basename(os.readlink(p)) == safe_uuid:
                        os.unlink(p)
        return "Deleted", 200
    except Exception as e: return f"Error: {e}", 500

@app.route('/api/templates', methods=['GET'])
def list_templates_api():
    if not check_auth(): return "Unauthorized", 401
    return jsonify(get_templates_list())

@app.route('/api/templates', methods=['POST'])
def create_template():
    if not check_auth(): return "Unauthorized", 401
    name = request.form.get('name')
    tmpl_type = request.form.get('type', 'standard')
    if not name: return "Missing name", 400
    safe_name = "".join([c for c in name if c.isalnum() or c in ('-', '_')])
    if not safe_name: return "Invalid name", 400
    if tmpl_type not in ('standard', 'sk', 'opk'): return "Invalid type", 400
    template_path = os.path.join(SSH_TEMPLATE_DIR, safe_name)
    if os.path.exists(template_path): return "Exists", 400
    try:
        os.makedirs(template_path, mode=0o700)
        if tmpl_type == 'standard':
            key_path = os.path.join(template_path, "id_ed25519")
            subprocess.run(['ssh-keygen', '-t', 'ed25519', '-f', key_path, '-N', '', '-C', f"template:{safe_name}"], check=True, capture_output=True)
        # For sk/opk, template dir is created empty — key generation happens via terminal
        return "OK", 200
    except Exception as e: return f"Error: {e}", 500

@app.route('/api/templates/<name>', methods=['DELETE'])
def delete_template(name):
    if not check_auth(): return "Unauthorized", 401
    safe_name = os.path.basename(name)
    template_path = os.path.join(SSH_TEMPLATE_DIR, safe_name)
    if not os.path.exists(template_path): return "Not found", 404
    try:
        shutil.rmtree(template_path)
        return "Deleted", 200
    except Exception as e: return f"Error: {e}", 500

@app.route('/api/history', methods=['GET'])
def get_history():
    if not check_auth(): return "Unauthorized", 401
    entries = []
    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, 'r') as f:
                lines = f.readlines()
                for line in reversed(lines):
                    line = line.strip()
                    if not line: continue
                    parts = line.split('|')
                    entries.append({
                        'ts': parts[0] if len(parts)>0 else '',
                        'user': parts[1] if len(parts)>1 else '',
                        'action': parts[2] if len(parts)>2 else '',
                        'target': parts[3] if len(parts)>3 else '',
                        'details': parts[4] if len(parts)>4 else ''
                    })
                    if len(entries) >= 100: break
        except Exception: pass
    return jsonify(entries)

def shutdown():
    os.kill(os.getpid(), signal.SIGINT)
    return "Shutting down..."

def open_browser(port):
    url = f"http://{HOST}:{port}/?token={AUTH_TOKEN}"
    print(f"==================================================")
    print(f" SSH UI Authenticated URL:")
    print(f" {url}")
    print(f"==================================================")
    webbrowser.open(url)

# --- WebSocket Events (If Available) ---
if SOCKETIO_AVAILABLE:
    
    def read_and_forward_pty_output(fd, term_id):
        sys.stderr.write(f"DEBUG: Starting PTYReader for term {term_id} (fd={fd})\n")
        try:
            while True:
                # Use select to check for data availability (non-blocking check)
                try:
                    r, _, _ = select.select([fd], [], [], 0.1)
                except (OSError, ValueError):
                    # FD likely closed
                    break
                    
                if fd in r:
                    try:
                        data = os.read(fd, 1024)
                    except OSError:
                        break # FD closed
                    
                    if not data:
                        sys.stderr.write(f"DEBUG: PTY EOF for term {term_id}\n")
                        # Emit session_ended event so frontend can close window/modal
                        if term_id in active_terminals:
                            current_sid = active_terminals[term_id]['sid']
                            socketio.emit('session_ended', {}, room=current_sid)
                        break
                        
                    # Find current SID
                    if term_id in active_terminals:
                        current_sid = active_terminals[term_id]['sid']
                        socketio.emit('output', {'data': data.decode('utf-8', errors='ignore')}, room=current_sid)

                else:
                    # Timeout, check if we should keep running? 
                    pass
                    
        except Exception as e:
            logger.error(f"PTY Read error: {e}")
            sys.stderr.write(f"DEBUG: PTYReader Exception: {e}\n")
        finally:
            logger.info(f"PTYReader for term {term_id} finished.")
            if term_id in active_terminals:
                 # Clean up specific to reader thread if needed
                 pass

    @socketio.on('connect_terminal')
    def handle_terminal_connect(data):
        """
        Received payload: { 'cmd': 'create' or 'connect', 'args': ... }
        Spawns the PTY.
        """
        sid = request.sid
        cmd_type = data.get('cmd')
        term_id = data.get('term_id') or sid # Use SID if no term_id provided (fallback)
        
        logger.info(f"Socket connection request: {cmd_type} from {sid} (term_id={term_id})")

        # Check for existing session
        if term_id in active_terminals:
            session = active_terminals[term_id]
            # Cancel any pending kill timer
            if session.get('timer'):
                try:
                    session['timer'].kill()
                except Exception:
                    pass
                session['timer'] = None
            
            # Update SID mapping
            old_sid = session.get('sid')
            if old_sid in sid_to_term: del sid_to_term[old_sid]
            
            session['sid'] = sid
            sid_to_term[sid] = term_id
            
            # Re-attach reader thread?
            # The reader thread writes to `socketio.emit(..., room=sid)`.
            # We need to update the reader thread? 
            # Actually, the reader thread uses `sid` passed to it.
            # We can't easily change the local variable in the running thread.
            # SOLUTION: Store the current SID in the mutable session dict, 
            # and have the reader thread lookup the current SID from the dict!
            
            # Let's respawn the reader? No, FD is being read.
            # Only one reader allowed.
            # Modified reader below to lookup SID dynamically.
            
            logger.info(f"Re-attached to existing PTY {session['pid']}")
            emit('output', {'data': f"\r\n--- Re-attached to session ---\r\n"})
            return

        
        # Build the shell command
        # Re-using the logic from legacy endpoints conceptually, but we execute directly
        shell_cmd = []
        sys.stderr.write(f"DEBUG: Received connect_terminal: {cmd_type}\n")
        
        if cmd_type == 'create':
            # args: user_host, template, key_comment
            uh = data.get('user_host')
            tmpl = data.get('template')
            kc = data.get('key_comment')
            if not uh: return
            
            # Simple sanitization
            safe_host = "".join([c for c in uh if c.isalnum() or c in ('-', '_', '.', '@')])
            
            ssh_new = os.path.join(BIN_DIR, "ssh-new")
            shell_cmd = [ssh_new]
            if data.get('legacy'): shell_cmd.append('--legacy')
            if tmpl and tmpl != 'none': shell_cmd.extend(['--template', tmpl])
            if kc: shell_cmd.extend(['--key-comment', kc])
            shell_cmd.append(safe_host)
            
        elif cmd_type == 'template':
            # args: action (generate-sk, generate-opk), name
            action = data.get('action')
            name = data.get('name')
            if not action or not name: return
            safe_name = "".join([c for c in name if c.isalnum() or c in ('-', '_')])
            if not safe_name: return
            if action not in ('generate-sk', 'generate-opk', 'generate-keys'): return
            ssh_template = os.path.join(BIN_DIR, "ssh-template")
            shell_cmd = [ssh_template, action, safe_name]

        elif cmd_type == 'connect':
            # args: user, host
            u = data.get('user')
            h = data.get('host')
            # Validation
            safe_u = "".join([c for c in u if c.isalnum() or c in ('-', '_', '.')])
            safe_h = "".join([c for c in h if c.isalnum() or c in ('-', '_', '.', '@')])
            target = f"{safe_u}@{safe_h}"
            
            shell_cmd = ['ssh', target]
            sys.stderr.write(f"DEBUG: shell_cmd: {shell_cmd}\n")
            
        else:
            return

        # Spawn PTY
        try:
            # pid, fd = pty.fork()
            # BUT pty.fork is UNIX only.
            
            pid, fd = pty.fork()
            
            if pid == 0:
                # CHILD
                # Ensure TERM is set so ssh/apps know how to behave
                os.environ['TERM'] = 'xterm-256color'
                
                try:
                    os.execvp(shell_cmd[0], shell_cmd)
                except Exception as e:
                    print(f"Failed to exec: {e}")
                    sys.exit(1)
            else:
                # PARENT
                # PARENT
                active_terminals[term_id] = {'fd': fd, 'pid': pid, 'sid': sid, 'timer': None}
                sid_to_term[sid] = term_id
                
                # Start reader thread
                socketio.start_background_task(target=read_and_forward_pty_output, fd=fd, term_id=term_id)
                
                logger.info(f"Spawned PTY (pid={pid}) for {sid} (term_id={term_id})")
                
        except Exception as e:
            logger.error(f"Failed to spawn PTY: {e}")
            sys.stderr.write(f"DEBUG: Exception launching PTY: {e}\n")
            emit('output', {'data': f"\r\nError launching process: {e}\r\n"})

    @socketio.on('input')
    def handle_terminal_input(data):
        sid = request.sid
        term_id = sid_to_term.get(sid)
        if term_id and term_id in active_terminals:
            fd = active_terminals[term_id]['fd']
            try:
                os.write(fd, data['data'].encode('utf-8'))
            except OSError:
                pass

    @socketio.on('resize')
    def handle_terminal_resize(data):
        sid = request.sid
        term_id = sid_to_term.get(sid)
        if term_id and term_id in active_terminals:
            fd = active_terminals[term_id]['fd']
            cols = data.get('cols', 80)
            rows = data.get('rows', 24)
            try:
                winsize = struct.pack("HHHH", rows, cols, 0, 0)
                fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
            except Exception:
                pass

    @socketio.on('disconnect')
    def handle_disconnect():
        sid = request.sid
        term_id = sid_to_term.get(sid)
        
        if term_id and term_id in active_terminals:
            # Don't kill immediately. Set a grace period.
            logger.info(f"Client {sid} disconnected. Scheduling cleanup for term {term_id}.")
            
            def cleanup_task():
                time.sleep(15) # 15 seconds grace period
                if term_id in active_terminals:
                    session = active_terminals[term_id]
                    # If SID hasn't changed (still disconnected)
                    if session['sid'] == sid:
                        logger.info(f"Grace period expired for {term_id}. Killing PTY.")
                        pid = session['pid']
                        fd = session['fd']
                        try:
                            os.close(fd)
                            os.waitpid(pid, os.WNOHANG)
                        except: pass
                        del active_terminals[term_id]
                        if sid in sid_to_term: del sid_to_term[sid]
                    else:
                        logger.info(f"Cleanup aborted for {term_id} (reconnected).")

            timer = socketio.start_background_task(target=cleanup_task)
            active_terminals[term_id]['timer'] = timer


# Helper to find a free port
def get_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('', 0))
        addr, port = s.getsockname()
        return port

def check_port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(('127.0.0.1', port)) == 0

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="SSH UI Server")
    parser.add_argument('--port', type=int, help="Port to listen on (default: random)")
    args = parser.parse_args()

    if args.port:
        if check_port_in_use(args.port):
            print(f"Error: Port {args.port} is already in use.")
            sys.exit(1)
        PORT = args.port
    else:
        # Random port
        PORT = get_free_port()

    print(f"Starting SSH UI on {HOST}:{PORT}")
    if SOCKETIO_AVAILABLE:
        print(" -> WebSockets ENABLED (xterm.js support active)")
    else:
        print(" -> WebSockets DISABLED (Legacy mode)")

    # Restrict SocketIO CORS to localhost on the actual port
    if SOCKETIO_AVAILABLE:
        allowed = [f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"]
        socketio.server.cors_allowed_origins = allowed

    threading.Timer(1.0, open_browser, args=[PORT]).start()

    # Update app port
    if SOCKETIO_AVAILABLE:
        socketio.run(app, host=HOST, port=PORT, debug=False)
    else:
        app.run(host=HOST, port=PORT, debug=False)
