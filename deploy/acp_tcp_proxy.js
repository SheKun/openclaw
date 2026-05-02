const fs = require("node:fs");
const net = require("node:net");

const upstreamHost = "coder-copilot";
const upstreamPort = 8765;
const socketPath = process.argv[2];
const socketIdFile = process.argv[3];
const statusFile = process.argv[4];
const rpcLogFile =
  process.argv[5] ||
  process.env.CODER_COPILOT_PROXY_RPC_LOG_FILE ||
  "/tmp/coder-copilot-acp.rpc.log";

if (!socketPath || !socketIdFile || !statusFile) {
  console.error(
    "Usage: node acp_tcp_proxy.js <socket-path> <socket-id-file> <status-file> [rpc-log-file]",
  );
  process.exit(1);
}

let upstream = null;
let activeClient = null;
let reconnectTimer = null;
let upstreamConnected = false;
let lastUpstreamError = "upstream not connected";
const rpcLineBuffers = {
  "C->S": "",
  "S->C": "",
};

function logProxyLine(message) {
  const line = `${new Date().toISOString()} ${message}\n`;
  try {
    fs.appendFileSync(rpcLogFile, line, "utf8");
  } catch (err) {
    process.stderr.write(`[acp_tcp_proxy] failed to write rpc log: ${err.message}\n`);
  }
}

function summarizeJsonRpcMessage(parsed) {
  const id = Object.prototype.hasOwnProperty.call(parsed, "id") ? parsed.id : undefined;
  const hasMethod = typeof parsed.method === "string" && parsed.method.length > 0;
  const hasResult = Object.prototype.hasOwnProperty.call(parsed, "result");
  const hasError = Object.prototype.hasOwnProperty.call(parsed, "error");

  if (hasMethod) {
    if (id === undefined) {
      return `notification method=${parsed.method}`;
    }
    return `request id=${JSON.stringify(id)} method=${parsed.method}`;
  }

  if (id !== undefined && hasError) {
    const code =
      parsed &&
      typeof parsed.error === "object" &&
      parsed.error !== null &&
      Object.prototype.hasOwnProperty.call(parsed.error, "code")
        ? parsed.error.code
        : "unknown";
    return `response-error id=${JSON.stringify(id)} code=${JSON.stringify(code)}`;
  }

  if (id !== undefined && hasResult) {
    return `response id=${JSON.stringify(id)}`;
  }

  return "message";
}

function logRpcLine(direction, line) {
  const trimmed = line.trim();
  if (!trimmed) {
    return;
  }

  try {
    const parsed = JSON.parse(trimmed);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const summary = summarizeJsonRpcMessage(parsed);
      logProxyLine(`${direction} ${summary} raw=${trimmed}`);
      return;
    }
  } catch {}

  logProxyLine(`${direction} raw=${trimmed}`);
}

function logRpcChunk(direction, chunk) {
  const text = chunk.toString("utf8");
  const next = `${rpcLineBuffers[direction]}${text}`;
  const lines = next.split("\n");
  rpcLineBuffers[direction] = lines.pop() || "";

  for (const line of lines) {
    logRpcLine(direction, line);
  }
}

function flushRpcBuffer(direction) {
  const buffered = rpcLineBuffers[direction];
  if (!buffered) {
    return;
  }
  rpcLineBuffers[direction] = "";
  logRpcLine(direction, buffered);
}

function writeStatus(state, reason = "") {
  fs.writeFileSync(
    statusFile,
    JSON.stringify({ state, reason, updatedAt: new Date().toISOString() }) + "\n",
    "utf8",
  );
}

function cleanupFiles() {
  try {
    fs.unlinkSync(socketPath);
  } catch {}

  try {
    fs.unlinkSync(socketIdFile);
  } catch {}

  try {
    fs.unlinkSync(statusFile);
  } catch {}
}

logProxyLine(
  `[acp_tcp_proxy] starting upstream=${upstreamHost}:${upstreamPort} socket=${socketPath}`,
);

function scheduleReconnect() {
  if (reconnectTimer) {
    return;
  }

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectUpstream();
  }, 500);
}

function connectUpstream() {
  if (upstream && !upstream.destroyed) {
    return;
  }

  writeStatus("connecting", lastUpstreamError);
  upstream = net.createConnection({ host: upstreamHost, port: upstreamPort });
  upstream.setKeepAlive(true, 10_000);

  upstream.on("connect", () => {
    upstreamConnected = true;
    lastUpstreamError = "";
    writeStatus("ready");
    process.stderr.write(`[acp_tcp_proxy] connected to ${upstreamHost}:${upstreamPort}\n`);
  });

  upstream.on("data", (chunk) => {
    logRpcChunk("S->C", chunk);
    if (activeClient && !activeClient.destroyed) {
      activeClient.write(chunk);
    }
  });

  upstream.on("error", (err) => {
    upstreamConnected = false;
    lastUpstreamError = err.message;
    writeStatus("error", lastUpstreamError);

    if (activeClient && !activeClient.destroyed) {
      activeClient.destroy();
      activeClient = null;
    }

    process.stderr.write(`[acp_tcp_proxy] upstream error: ${err.message}\n`);
  });

  upstream.on("close", () => {
    flushRpcBuffer("S->C");
    upstreamConnected = false;
    if (!lastUpstreamError) {
      lastUpstreamError = "upstream closed";
    }
    writeStatus("disconnected", lastUpstreamError);

    if (activeClient && !activeClient.destroyed) {
      activeClient.destroy();
      activeClient = null;
    }

    upstream = null;
    scheduleReconnect();
  });
}

function handleClient(client) {
  if (!upstreamConnected) {
    client.destroy();
    return;
  }

  if (activeClient && !activeClient.destroyed) {
    client.destroy();
    return;
  }

  activeClient = client;
  connectUpstream();

  client.on("data", (chunk) => {
    logRpcChunk("C->S", chunk);
    if (upstream && !upstream.destroyed) {
      upstream.write(chunk);
    }
  });

  client.on("error", () => {});

  client.on("close", () => {
    flushRpcBuffer("C->S");
    if (activeClient === client) {
      activeClient = null;
    }
  });
}

cleanupFiles();
writeStatus("starting", lastUpstreamError);
connectUpstream();

const server = net.createServer(handleClient);

server.listen(socketPath, () => {
  fs.writeFileSync(socketIdFile, `${socketPath}\n`, "utf8");
  process.stderr.write(`[acp_tcp_proxy] listening on ${socketPath}\n`);
});

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    flushRpcBuffer("C->S");
    flushRpcBuffer("S->C");
    server.close(() => {
      if (upstream && !upstream.destroyed) {
        upstream.destroy();
      }
      cleanupFiles();
      process.exit(0);
    });
  });
}
