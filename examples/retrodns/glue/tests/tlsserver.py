# (tests/check.sh) A TLS server on this computer for SplitTest: DNS over HTTPS on the first port, DNS over
# TLS on the second; it says how the first bytes of each connection came (the hello: in pieces or
# whole), then answers every query with one address.
import socket, ssl, threading, sys, struct
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain('cert.pem', 'key.pem')
pieces = []
def answer(q):
    # an answer: the query back with QR set and one A record 1.2.3.4
    r = bytearray(q); r[2] |= 0x80; r[3] = 0x80; r[6:8] = b'\x00\x01'
    return bytes(r) + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x01\x02\x03\x04'
def serve(port, kind):
    ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(('127.0.0.1', port)); ls.listen(5)
    while True:
        c, _ = ls.accept()
        # the first bytes, as they come: how many in each read (the hello's pieces)
        c.settimeout(5); got = b''; sizes = []
        try:
            while len(got) < 5 or len(got) < 5 + struct.unpack('>H', got[3:5])[0]:
                b = c.recv(65536)
                if not b: break
                sizes.append(len(b)); got += b; c.settimeout(0.5)
        except socket.timeout: pass
        pieces.append((kind, sizes))
        print(kind, 'hello reads', sizes, flush=True)
        c.settimeout(5)
        class Pre(socket.socket): pass
        # put the bytes back: a socketpair relay
        a, b2 = socket.socketpair()
        def relay(src, dst):
            try:
                while True:
                    d = src.recv(65536)
                    if not d: break
                    dst.sendall(d)
            except Exception: pass
            try: dst.shutdown(socket.SHUT_WR)
            except Exception: pass
        b2.sendall(got)
        threading.Thread(target=relay, args=(c, b2), daemon=True).start()
        threading.Thread(target=relay, args=(b2, c), daemon=True).start()
        def handle(sock):
            try:
                s = ctx.wrap_socket(sock, server_side=True)
                if kind == 'dot':
                    while True:
                        n = struct.unpack('>H', s.recv(2))[0]; q = b''
                        while len(q) < n: q += s.recv(n - len(q))
                        a2 = answer(q); s.sendall(struct.pack('>H', len(a2)) + a2)
                else:
                    buf = b''
                    while True:
                        while b'\r\n\r\n' not in buf: buf += s.recv(4096)
                        head, buf = buf.split(b'\r\n\r\n', 1)
                        n = int([l.split(b':')[1] for l in head.split(b'\r\n') if l.lower().startswith(b'content-length')][0])
                        while len(buf) < n: buf += s.recv(4096)
                        q, buf = buf[:n], buf[n:]
                        a2 = answer(q)
                        s.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: %d\r\n\r\n' % len(a2) + a2)
            except Exception as e: print(kind, 'end', e, flush=True)
        threading.Thread(target=handle, args=(a,), daemon=True).start()
threading.Thread(target=serve, args=(int(sys.argv[1]), 'doh'), daemon=True).start()
threading.Thread(target=serve, args=(int(sys.argv[2]), 'dot'), daemon=True).start()
print('ready', flush=True)
threading.Event().wait()
