(function() {
    'use strict';

    // State
    let ws = null;
    let sessionId = localStorage.getItem('sessionId');
    let username = localStorage.getItem('username') || '';
    let currentRoom = 'general';
    let rooms = {};

    // DOM elements
    const loginScreen = document.getElementById('login-screen');
    const chatScreen = document.getElementById('chat-screen');
    const loginForm = document.getElementById('login-form');
    const usernameInput = document.getElementById('username');
    const messageForm = document.getElementById('message-form');
    const messageInput = document.getElementById('message-input');
    const messagesDiv = document.getElementById('messages');
    const roomsList = document.getElementById('rooms-list');
    const usersList = document.getElementById('users-list');
    const displayName = document.getElementById('display-name');
    const currentRoomEl = document.getElementById('current-room');
    const connectionStatus = document.getElementById('connection-status');
    const newRoomInput = document.getElementById('new-room');

    // Login
    loginForm.addEventListener('submit', (e) => {
        e.preventDefault();
        username = usernameInput.value.trim();
        if (username) {
            localStorage.setItem('username', username);
            connect();
        }
    });

    // Auto-connect if we have a username
    if (username) {
        usernameInput.value = username;
        connect();
    }

    function connect() {
        const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        let url = `${protocol}//${location.host}/ws/chat?name=${encodeURIComponent(username)}`;
        if (sessionId) {
            url += `&session=${encodeURIComponent(sessionId)}`;
        }

        ws = new WebSocket(url);
        setStatus('connecting', '...');

        ws.onopen = () => {
            setStatus('connected', 'OK');
        };

        ws.onclose = () => {
            setStatus('disconnected', 'X');
            setTimeout(connect, 2000);
        };

        ws.onerror = () => {
            setStatus('disconnected', '!');
        };

        ws.onmessage = (e) => {
            const msg = JSON.parse(e.data);
            handleMessage(msg);
        };
    }

    function setStatus(cls, text) {
        connectionStatus.className = 'status ' + cls;
        connectionStatus.textContent = text;
    }

    function handleMessage(msg) {
        switch (msg.type) {
            case 'connected':
                sessionId = msg.session_id;
                localStorage.setItem('sessionId', sessionId);
                displayName.textContent = msg.name;
                updateRoomsList(msg.rooms.map(r => ({ name: r })));
                loginScreen.classList.add('hidden');
                chatScreen.classList.remove('hidden');
                break;

            case 'resumed':
                sessionId = msg.session_id;
                displayName.textContent = msg.name;
                loginScreen.classList.add('hidden');
                chatScreen.classList.remove('hidden');
                break;

            case 'joined':
                currentRoom = msg.room;
                currentRoomEl.textContent = '#' + msg.room;
                rooms[msg.room] = true;
                updateRoomsList(Object.keys(rooms).map(r => ({ name: r })));
                messagesDiv.innerHTML = '';
                if (msg.history) {
                    msg.history.forEach(m => addMessage(m));
                }
                updateUsersList(msg.users || []);
                break;

            case 'left':
                delete rooms[msg.room];
                updateRoomsList(Object.keys(rooms).map(r => ({ name: r })));
                break;

            case 'message':
            case 'action':
                if (msg.room === currentRoom) {
                    addMessage(msg);
                }
                break;

            case 'system':
                addMessage({ type: 'system', text: msg.text, from: 'system' });
                break;

            case 'user_joined':
            case 'user_left':
                if (msg.room === currentRoom) {
                    addMessage({ type: 'system', text: `${msg.user} ${msg.type === 'user_joined' ? 'joined' : 'left'}` });
                    updateUsersList(msg.users || []);
                }
                break;

            case 'room_list':
                updateRoomsList(msg.rooms);
                break;

            case 'user_list':
                if (msg.room === currentRoom) {
                    updateUsersList(msg.users);
                }
                break;

            case 'error':
                addMessage({ type: 'system', text: 'Error: ' + msg.message });
                break;

            case 'ping':
                send({ type: 'pong', ts: msg.ts });
                break;
        }
    }

    function addMessage(msg) {
        const div = document.createElement('div');
        const isOwn = msg.from === displayName.textContent;

        if (msg.type === 'system') {
            div.className = 'message system';
            div.textContent = msg.text;
        } else {
            div.className = 'message ' + (isOwn ? 'own' : 'other');
            div.innerHTML = `
                <div class="message-header">
                    <span class="message-author">${escapeHtml(msg.from)}</span>
                    <span class="message-time">${formatTime(msg.ts)}</span>
                </div>
                <div class="message-text">${escapeHtml(msg.text)}</div>
            `;
        }

        messagesDiv.appendChild(div);
        messagesDiv.scrollTop = messagesDiv.scrollHeight;
    }

    function updateRoomsList(roomList) {
        roomsList.innerHTML = roomList.map(r =>
            `<li class="${r.name === currentRoom ? 'active' : ''}" data-room="${r.name}">#${r.name}</li>`
        ).join('');

        roomsList.querySelectorAll('li').forEach(li => {
            li.addEventListener('click', () => {
                const room = li.dataset.room;
                if (room !== currentRoom) {
                    send({ type: 'join', room });
                }
            });
        });
    }

    function updateUsersList(users) {
        usersList.innerHTML = users.map(u =>
            `<li>${escapeHtml(u.name)}</li>`
        ).join('');
        document.getElementById('stat-users').textContent = users.length;
    }

    // Send message
    messageForm.addEventListener('submit', (e) => {
        e.preventDefault();
        const text = messageInput.value.trim();
        if (text) {
            send({ type: 'message', room: currentRoom, text });
            messageInput.value = '';
        }
    });

    // New room
    newRoomInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            const room = newRoomInput.value.trim().toLowerCase().replace(/[^\w-]/g, '');
            if (room) {
                send({ type: 'join', room });
                newRoomInput.value = '';
            }
        }
    });

    function send(msg) {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify(msg));
        }
    }

    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    function formatTime(ts) {
        if (!ts) return '';
        const d = new Date(ts * 1000);
        return d.toLocaleTimeString();
    }

    // Fetch stats periodically
    setInterval(async () => {
        try {
            const res = await fetch('/api/stats');
            const stats = await res.json();
            document.getElementById('stat-users').textContent = stats.users_online || 0;
            document.getElementById('stat-rooms').textContent = stats.rooms_count || 0;
        } catch (e) {}
    }, 10000);
})();
