const net = require("node:net");

const socketPath = process.argv[2];

if (!socketPath) {
  console.error("Usage: node acp_stdio_to_socket.js <socket-path>");
  process.exit(1);
}

const socket = net.createConnection(socketPath, () => {
  process.stdin.pipe(socket);
});

socket.pipe(process.stdout);

let stdinEnded = false;
let settled = false;

function fail(message) {
  if (settled) {
    return;
  }
  settled = true;
  console.error(`[acp_stdio_to_socket] ${message}`);
  process.exit(1);
}

function succeed() {
  if (settled) {
    return;
  }
  settled = true;
  process.exit(0);
}

socket.on("error", (err) => {
  fail(`connect failed (${socketPath}): ${err.message}`);
});

socket.on("end", () => {
  if (!stdinEnded) {
    fail("proxy disconnected before stdin closed (upstream unavailable)");
    return;
  }
  succeed();
});

socket.on("close", (hadError) => {
  if (hadError) {
    fail("connection closed with transport error");
    return;
  }

  if (!stdinEnded) {
    fail("connection closed unexpectedly before stdin closed");
  }
});

process.stdin.on("end", () => {
  stdinEnded = true;
  socket.end();
});
