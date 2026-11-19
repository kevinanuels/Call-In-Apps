// Minimal WebRTC signaling server: registers users by id and relays messages.
const http = require('http');
const { WebSocketServer } = require('ws');
const PORT = process.env.PORT || 8080;

// Optional Telegram monitor (monitor.js is not part of the repo).
let monitor = null;
try { monitor = require('./monitor'); } catch { /* not installed */ }
const mon = (fn, ...a) => { try { return monitor && monitor[fn] ? monitor[fn](...a) : undefined; } catch (e) { console.error('monitor:', e.message); } };

const httpServer = http.createServer((req, res) => { res.writeHead(200); res.end('ok'); }); // health check
const wss = new WebSocketServer({ server: httpServer });
const users = new Map(); // id -> ws
mon('init', { users, wss });

wss.on('connection', (ws, req) => {
  let myId = null;
  ws.isAlive = true;
  mon('onConnect', ws, req);
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', (raw) => {
    ws.isAlive = true;
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'register') {
      const id = String(msg.id || '').trim();
      if (!id) return;
      if (mon('isBlocked', id)) {
        mon('onBlockedAttempt', id, ws);
        ws.send(JSON.stringify({ type: 'blocked' }));
        ws.close(4003, 'blocked');
        return;
      }
      myId = id;
      users.set(myId, ws);
      ws.send(JSON.stringify({ type: 'registered', id: myId }));
      console.log('registered', myId);
      mon('onRegister', myId, ws);
      return;
    }
    if (msg.type === 'ping') { ws.send(JSON.stringify({ type: 'pong' })); return; }
    if (!myId || !msg.to) return;
    const target = users.get(msg.to);
    if (!target || target.readyState !== 1) {
      ws.send(JSON.stringify({ type: 'unavailable', from: msg.to }));
      mon('onRelay', myId, msg, false, raw.length);
      return;
    }
    target.send(JSON.stringify({ ...msg, from: myId })); // offer/answer/ice/hangup/reject
    mon('onRelay', myId, msg, true, raw.length);
  });
  ws.on('close', () => {
    const replaced = myId && users.get(myId) !== ws; // superseded by a newer connection
    if (myId && !replaced) users.delete(myId);
    console.log('left', myId);
    if (!replaced) mon('onClose', myId, ws);
  });
});
httpServer.listen(PORT, () => console.log(`Signaling server on port ${PORT}`));

// Drop half-open connections so stale registrations don't linger.
setInterval(() => {
  wss.clients.forEach((c) => {
    if (!c.isAlive) return c.terminate();
    c.isAlive = false;
    c.ping();
  });
}, 30000);
