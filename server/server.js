// Minimal WebRTC signaling server: registers users by id and relays messages.
const http = require('http');
const { WebSocketServer } = require('ws');
const PORT = process.env.PORT || 8080;
const httpServer = http.createServer((req, res) => { res.writeHead(200); res.end('ok'); }); // health check
const wss = new WebSocketServer({ server: httpServer });
const users = new Map(); // id -> ws

wss.on('connection', (ws) => {
  let myId = null;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', (raw) => {
    ws.isAlive = true;
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'register') {
      myId = String(msg.id || '').trim();
      if (!myId) return;
      users.set(myId, ws);
      ws.send(JSON.stringify({ type: 'registered', id: myId }));
      console.log('registered', myId);
      return;
    }
    if (msg.type === 'ping') { ws.send(JSON.stringify({ type: 'pong' })); return; }
    if (!myId || !msg.to) return;
    const target = users.get(msg.to);
    if (!target || target.readyState !== 1) {
      ws.send(JSON.stringify({ type: 'unavailable', from: msg.to }));
      return;
    }
    target.send(JSON.stringify({ ...msg, from: myId })); // offer/answer/ice/hangup/reject
  });
  ws.on('close', () => {
    if (myId && users.get(myId) === ws) users.delete(myId);
    console.log('left', myId);
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
