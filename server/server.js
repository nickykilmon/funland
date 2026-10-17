// FunLand website: serves the Godot web build from ./public and relays multiplayer
// packets between players in a room over WebSockets at /ws.
//
// Control messages are JSON text:  {t:"host", name, map} {t:"join", room} {t:"list"} {t:"kick", id}
// Game packets are binary: [int32 target][payload] from players, [int32 from][payload] to players.
// Target 0 = everyone else in the room, negative = everyone except that id.

const http = require("http");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 3123;
const PUBLIC = path.join(__dirname, "public");
const MAX_PLAYERS = 16;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".json": "application/json",
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    return res.end("ok");
  }
  let file = path.normalize(path.join(PUBLIC, decodeURIComponent(url.pathname)));
  if (!file.startsWith(PUBLIC)) {
    res.writeHead(403);
    return res.end();
  }
  if (url.pathname === "/" || url.pathname === "") file = path.join(PUBLIC, "index.html");
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      return res.end("Not found");
    }
    const headers = {
      "Content-Type": MIME[path.extname(file)] || "application/octet-stream",
      "Cache-Control": file.endsWith(".html") ? "no-cache" : "public, max-age=300",
    };
    // the big engine files shrink to about a quarter when gzipped
    if (/gzip/.test(req.headers["accept-encoding"] || "") && /\.(wasm|js|pck)$/.test(file)) {
      const gz = gzipped(file, st.mtimeMs);
      res.writeHead(200, { ...headers, "Content-Encoding": "gzip", "Content-Length": gz.length });
      return res.end(gz);
    }
    res.writeHead(200, { ...headers, "Content-Length": st.size });
    fs.createReadStream(file).pipe(res);
  });
});

const gzCache = new Map();
function gzipped(file, mtime) {
  const hit = gzCache.get(file);
  if (hit && hit.mtime === mtime) return hit.data;
  const data = zlib.gzipSync(fs.readFileSync(file), { level: 9 });
  gzCache.set(file, { mtime, data });
  return data;
}

// room code -> { code, name, map, players: Map<id, ws> }
const rooms = new Map();

function newCode() {
  const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  let code;
  do {
    code = "";
    for (let i = 0; i < 4; i++) code += letters[Math.floor(Math.random() * letters.length)];
  } while (rooms.has(code));
  return code;
}

function newId(room) {
  let id;
  do id = 2 + Math.floor(Math.random() * 2147483000);
  while (room.players.has(id));
  return id;
}

function send(ws, obj) {
  if (ws.readyState === 1) ws.send(JSON.stringify(obj));
}

function roomList() {
  return [...rooms.values()].map((r) => ({ code: r.code, name: r.name, map: r.map, players: r.players.size }));
}

const wss = new WebSocketServer({ server, path: "/ws", maxPayload: 32 * 1024 * 1024 });

wss.on("connection", (ws) => {
  ws.alive = true;
  ws.on("pong", () => (ws.alive = true));

  ws.on("message", (data, isBinary) => {
    if (isBinary) return relay(ws, data);
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (msg.t === "list") return send(ws, { t: "rooms", rooms: roomList() });
    if (ws.room) {
      if (msg.t === "kick" && ws.id === 1) {
        const target = ws.room.players.get(Number(msg.id));
        if (target) target.close();
      }
      return;
    }
    if (msg.t === "host") {
      const room = { code: newCode(), name: String(msg.name || "Someone").slice(0, 16), map: String(msg.map || "").slice(0, 20), players: new Map() };
      rooms.set(room.code, room);
      ws.room = room;
      ws.id = 1;
      room.players.set(1, ws);
      send(ws, { t: "welcome", id: 1, room: room.code, peers: [] });
    } else if (msg.t === "join") {
      const room = rooms.get(String(msg.room || "").toUpperCase().trim());
      if (!room) return send(ws, { t: "error", msg: "That room doesn't exist (anymore). Check the code." });
      if (room.players.size >= MAX_PLAYERS) return send(ws, { t: "error", msg: "That room is full." });
      const id = newId(room);
      const peers = [...room.players.keys()];
      for (const other of room.players.values()) send(other, { t: "peer", id });
      ws.room = room;
      ws.id = id;
      room.players.set(id, ws);
      send(ws, { t: "welcome", id, room: room.code, peers });
    }
  });

  ws.on("close", () => {
    const room = ws.room;
    if (!room) return;
    room.players.delete(ws.id);
    if (ws.id === 1) {
      // host left: the room is over
      rooms.delete(room.code);
      for (const other of room.players.values()) other.close();
    } else {
      for (const other of room.players.values()) send(other, { t: "left", id: ws.id });
    }
  });
});

function relay(ws, data) {
  const room = ws.room;
  if (!room || data.length < 4) return;
  const target = data.readInt32LE(0);
  data.writeInt32LE(ws.id, 0); // reuse the header slot for the sender id
  if (target > 0) {
    const to = room.players.get(target);
    if (to && to.readyState === 1) to.send(data);
    return;
  }
  for (const [id, other] of room.players) {
    if (id === ws.id || (target < 0 && id === -target)) continue;
    if (other.readyState === 1) other.send(data);
  }
}

// keep connections alive through proxies, drop dead ones
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.alive) {
      ws.terminate();
      continue;
    }
    ws.alive = false;
    ws.ping();
  }
}, 25000);

server.listen(PORT, () => console.log(`FunLand server on http://localhost:${PORT}`));
