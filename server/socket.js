const { Server } = require('socket.io');
const jwt = require('jsonwebtoken');
const { JWT_SECRET } = require('./middleware/auth');
const { isAllowedOrigin } = require('./config/origins');

let io = null;

const POLICE_ROOM = 'police';

// Token may arrive via handshake.auth.token (preferred), handshake.query.token,
// `join` payload token, or an Authorization header. Self-asserted `role`
// alone is never sufficient to join the police room.
const extractHandshakeToken = (socket) => {
  if (socket.handshake.auth && typeof socket.handshake.auth.token === 'string' && socket.handshake.auth.token) {
    return socket.handshake.auth.token;
  }
  if (socket.handshake.query && typeof socket.handshake.query.token === 'string' && socket.handshake.query.token) {
    return socket.handshake.query.token;
  }
  const authHeader = socket.handshake.headers && socket.handshake.headers.authorization;
  if (typeof authHeader === 'string' && authHeader.startsWith('Bearer ')) {
    return authHeader.slice(7);
  }
  return null;
};

// Same verification as server/middleware/auth.js: valid signature + police/admin role.
const isPoliceToken = (token) => {
  if (!token) return false;
  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    return !!decoded && (decoded.role === 'police' || decoded.role === 'admin');
  } catch {
    return false;
  }
};

const tryJoinPoliceRoom = (socket, token) => {
  if (isPoliceToken(token)) {
    socket.join(POLICE_ROOM);
  }
};

const initSocket = (httpServer) => {
  io = new Server(httpServer, {
    cors: {
      origin: (origin, callback) => callback(null, isAllowedOrigin(origin)),
      methods: ['GET', 'POST']
    }
  });

  io.on('connection', (socket) => {
    // NOTE: handshake.query.role / join.role alone grant nothing.
    // Only a valid JWT with role police/admin joins the police room,
    // otherwise the socket stays connected but receives no victim data
    // (io.to(POLICE_ROOM) broadcasts never reach it).
    tryJoinPoliceRoom(socket, extractHandshakeToken(socket));

    socket.on('join', (data) => {
      const token = (data && data.token) || extractHandshakeToken(socket);
      tryJoinPoliceRoom(socket, token);
    });

    socket.on('disconnect', () => {});
  });

  return io;
};

const getIO = () => io;

const emitNewCase = (caseData) => {
  if (io) {
    io.to(POLICE_ROOM).emit('new_case', caseData);
  }
};

const emitCaseUpdated = (caseData) => {
  if (io) {
    io.to(POLICE_ROOM).emit('case_updated', caseData);
  }
};

module.exports = { initSocket, getIO, emitNewCase, emitCaseUpdated, POLICE_ROOM };
