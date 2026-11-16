#!/usr/bin/env python3
"""ut99-bridge.py — datagram-preserving UDP<->TCP relay for the tailcat bridge.

Why this exists:
  tailcat carries TCP byte streams; UT99 speaks UDP. Bridging them as a raw
  byte stream (socat TCP-LISTEN ...,fork <-> UDP:...) loses datagram
  boundaries: TCP coalesces packet bursts into one read and socat fires the
  merged blob as one giant UDP datagram (or splits one datagram in pieces).
  UT99 then logs "Forged object", "Received unwanted function", "extra data
  received after socket close", disconnects clients as "corrupted packet",
  and can eventually die. This relay adds length-prefix framing so every
  datagram arrives intact. (This socat build lacks TUNNEL: addresses, which
  would do the same framing.)

Framing (the TCP hops here are always loopback to tailcat; the WAN hop is
tailcat's encrypted tunnel):
  frame = TYPE(1 byte) | LEN(2 bytes big endian) | payload[LEN]
  TYPE 0 OPEN  payload: channel, 1 byte: 0 = game port, 1 = server query
               port (game port + 1). Sent first on every new TCP connection
               so the host relay can map the channel to its own ports,
               independent of the local ports the client side uses.
  TYPE 1 DATA  payload: one raw UDP datagram.
  TYPE 2 CLOSE no payload.

Sessions (mirrors socat's fork model):
  client side: UDP datagrams on 7777/7778 from each distinct source
               ip:port get one TCP connection to the tailcat forward port.
  host side:   each accepted TCP connection gets one connected UDP socket
               to the server, so the server sees distinct 127.0.0.1:ephemeral
               clients, exactly as plain UDP bridging.

Usage:
  ut99-bridge.py host   [--tcp-bind 127.0.0.1] [--tcp-port 8777]
                        [--udp-host 127.0.0.1] [--udp-port 7777]
  ut99-bridge.py client [--udp-port 7777] [--no-query-port]
                        [--tcp-host 127.0.0.1] [--tcp-port 8777]
"""
import argparse
import errno
import selectors
import socket
import struct
import sys
import time

OPEN, DATA, CLOSE = 0, 1, 2
CH_GAME, CH_QUERY = 0, 1
IDLE_TIMEOUT_DEFAULT = 180.0  # > UT99's own 150 s silent-connection timeout


def log(msg):
    print(time.strftime("[bridge] %Y-%m-%d %H:%M:%S ") + msg, flush=True)


def send_frame(sock, typ, payload=b""):
    sock.sendall(struct.pack("!BH", typ, len(payload)) + payload)


def pop_frames(buf):
    """Yield (type, payload) for every complete frame in buf; consume them."""
    while True:
        if len(buf) < 3:
            return
        typ, ln = struct.unpack("!BH", buf[:3])
        if len(buf) < 3 + ln:
            return
        payload = bytes(buf[3:3 + ln])
        del buf[:3 + ln]
        yield typ, payload


class Pump:
    """Relay between one TCP connection and one UDP endpoint."""

    def __init__(self, sel, tcp, udp_send, idle_timeout):
        self.sel = sel
        self.tcp = tcp
        self.udp = None                   # host-side: the session's UDP socket
        self.udp_send = udp_send          # callable(payload) for UDP replies
        self.tcp.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.tcp.setblocking(False)
        self.buf = bytearray()
        self.idle_timeout = idle_timeout
        self.last = time.monotonic()
        self.alive = True
        sel.register(tcp, selectors.EVENT_READ, ("tcp", self))

    def close(self, why=""):
        if not self.alive:
            return
        self.alive = False
        # Unregister BEFORE close(): a closed socket's fileno() is -1, so the
        # selector would keep the stale fd mapping forever. The next socket
        # created then reuses that freed fd and sel.register() explodes with
        # "'... (FD 6) is already registered'" (seen after a client
        # disconnected and the next join crashed the host relay).
        for sock in (self.tcp, self.udp):
            if sock is None:
                continue
            try:
                self.sel.unregister(sock)
            except Exception:
                pass
            try:
                sock.close()
            except OSError:
                pass
        if why:
            log(f"session closed: {why}")

    def on_tcp_readable(self):
        try:
            chunk = self.tcp.recv(65535)
        except OSError as e:
            self.close(f"tcp error: {e}")
            return
        if not chunk:
            self.close("tcp eof")
            return
        self.last = time.monotonic()
        self.buf += chunk
        for typ, payload in pop_frames(self.buf):
            if typ == DATA:
                try:
                    self.udp_send(payload)
                except OSError as e:
                    self.close(f"udp send failed: {e}")
                    return
            elif typ == CLOSE:
                self.close()
                return
        if len(self.buf) > 262144:  # framed peer gone / desynced
            self.close("framing desync")

    def forward_udp(self, payload):
        """Hand one UDP datagram to the TCP side as a single DATA frame."""
        if not self.alive:
            return False
        self.last = time.monotonic()
        try:
            send_frame(self.tcp, DATA, payload)
        except OSError as e:
            self.close(f"tcp send failed: {e}")
            return False
        return True

    def check_idle(self, now):
        if self.alive and now - self.last > self.idle_timeout:
            self.close(f"idle > {self.idle_timeout:.0f}s")


def run_host(args):
    sel = selectors.DefaultSelector()
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind((args.tcp_bind, args.tcp_port))
    lsock.listen(16)
    lsock.setblocking(False)
    sel.register(lsock, selectors.EVENT_READ, ("accept", None))
    sessions = []  # live Pump objects (each owns its tcp + udp socket)
    log(f"host relay: TCP {args.tcp_bind}:{args.tcp_port} -> "
        f"UDP {args.udp_host}:{args.udp_port} (+query port) [framed]")

    def on_accept():
        try:
            tcp, peer = lsock.accept()
        except OSError as e:
            log(f"accept failed: {e}")
            return
        # Read the OPEN frame (max 5 s) before pumping.
        buf = bytearray()
        channel = None
        deadline = time.monotonic() + 5
        while channel is None and time.monotonic() < deadline:
            tcp.setblocking(False)
            ready = selectors.DefaultSelector()
            ready.register(tcp, selectors.EVENT_READ)
            events = ready.select(timeout=1.0)
            ready.close()
            if not events:
                continue
            try:
                chunk = tcp.recv(65535)
            except OSError:
                chunk = b""
            if not chunk:
                tcp.close()
                return
            buf += chunk
            while channel is None:
                if len(buf) < 3:
                    break
                typ, ln = struct.unpack("!BH", buf[:3])
                if len(buf) < 3 + ln:
                    break
                payload = bytes(buf[3:3 + ln])
                del buf[:3 + ln]
                if typ == OPEN and len(payload) == 1:
                    channel = payload[0]
                    # Whatever stayed in buf (e.g. DATA frames that arrived
                    # coalesced with OPEN) is handed to the Pump below.
                else:
                    log(f"bad first frame from {peer}; dropped")
                    tcp.close()
                    return
        if channel is None:
            log(f"connection from {peer} never sent OPEN within 5s; dropped")
            tcp.close()
            return
        port = args.udp_port + (1 if channel == CH_QUERY else 0)
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            udp.connect((args.udp_host, port))
        except OSError as e:
            log(f"udp connect to {args.udp_host}:{port} failed: {e}")
            tcp.close()
            return
        udp.setblocking(False)
        pump = Pump(sel, tcp, udp.send, args.idle_timeout)
        pump.buf = buf  # bytes already read past OPEN
        pump.udp = udp  # Pump.close() unregisters + closes it with the session
        sessions.append(pump)
        sel.register(udp, selectors.EVENT_READ, ("udp", pump))
        # DATA frames that arrived right behind OPEN:
        for typ, payload in pop_frames(pump.buf):
            if typ == DATA:
                try:
                    udp.send(payload)
                except OSError as e:
                    pump.close(f"udp send failed: {e}")
                    break

    while True:
        events = sel.select(timeout=1.0)
        for key, _ in events:
            kind = key.data[0]
            if kind == "accept":
                on_accept()
            elif kind == "tcp":
                pump = key.data[1]
                pump.on_tcp_readable()
            else:  # a session's UDP socket: the server's reply datagram
                pump = key.data[1]
                try:
                    payload, _ = key.fileobj.recvfrom(65535)
                except OSError as e:
                    pump.close(f"udp recv failed: {e}")
                    continue
                pump.forward_udp(payload)
        now = time.monotonic()
        for pump in sessions:
            pump.check_idle(now)  # close() unregisters + closes both sockets
        sessions[:] = [p for p in sessions if p.alive]


def run_client(args):
    sel = selectors.DefaultSelector()
    query_port = 0 if args.no_query_port else args.udp_port + 1
    listeners = {}  # udp socket -> (channel, port)
    for channel, port in ((CH_GAME, args.udp_port), (CH_QUERY, query_port)):
        if not port:
            continue
        us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        us.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        us.bind(("127.0.0.1", port))
        us.setblocking(False)
        sel.register(us, selectors.EVENT_READ, ("recv", (us, channel)))
        listeners[us] = (channel, port)
    sessions = {}  # (channel, src_ip, src_port) -> Pump
    log(f"client relay: UDP 127.0.0.1:{args.udp_port}"
        f"{'' if not query_port else f' +{query_port}'} -> "
        f"TCP {args.tcp_host}:{args.tcp_port} [framed]")
    last_conn_fail_log = 0.0

    while True:
        events = sel.select(timeout=1.0)
        for key, _ in events:
            kind = key.data[0]
            if kind == "tcp":
                pump = key.data[1]
                pump.on_tcp_readable()
                if not pump.alive:
                    for skey, p in list(sessions.items()):
                        if p is pump:
                            sessions.pop(skey, None)
                continue
            us, channel = key.data[1]
            while True:
                try:
                    payload, src = us.recvfrom(65535)
                except OSError as e:
                    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        break
                    break
                skey = (channel, src[0], src[1])
                pump = sessions.get(skey)
                if pump is None or not pump.alive:
                    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    try:
                        tcp.connect((args.tcp_host, args.tcp_port))
                    except OSError as e:
                        if time.monotonic() - last_conn_fail_log > 5:
                            last_conn_fail_log = time.monotonic()
                            log(f"tcp connect to tailcat port "
                                f"{args.tcp_port} failed: {e} "
                                f"(will keep retrying)")
                        continue
                    send_frame(tcp, OPEN, bytes([channel]))
                    pump = Pump(sel, tcp,
                                lambda p, u=us, a=src: u.sendto(p, a),
                                args.idle_timeout)
                    sessions[skey] = pump
                    log(f"session open: udp:{listeners[us][1]} "
                        f"<- {src[0]}:{src[1]}")
                pump.forward_udp(payload)
        now = time.monotonic()
        for skey, pump in list(sessions.items()):
            pump.check_idle(now)
            if not pump.alive:
                sessions.pop(skey, None)


def main():
    ap = argparse.ArgumentParser(
        description="datagram-framed UDP<->TCP relay for tailcat (UT99)")
    ap.add_argument("side", choices=["host", "client"])
    ap.add_argument("--tcp-bind", default="127.0.0.1")
    ap.add_argument("--tcp-port", type=int, default=8777)
    ap.add_argument("--tcp-host", default="127.0.0.1")
    ap.add_argument("--udp-host", default="127.0.0.1")
    ap.add_argument("--udp-port", type=int, default=7777)
    ap.add_argument("--no-query-port", action="store_true")
    ap.add_argument("--idle-timeout", type=float, default=IDLE_TIMEOUT_DEFAULT)
    args = ap.parse_args()
    try:
        if args.side == "host":
            run_host(args)
        else:
            run_client(args)
    except KeyboardInterrupt:
        log("bridge exiting (Ctrl+C)")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
