#!/usr/bin/env python3
"""A DNS server for the tests (retroui/dnsquery): answers from a zone file
over UDP and TCP on 127.0.0.1, at a port of its own, which it prints first.

    python3 tests/dnsmock.py tests/data/dkim/zone.txt

Each line of the file: "name TYPE data" (TYPE one of A, AAAA, MX, SRV, TXT)
or "name data" for a TXT record; "#" lines are notes. A name not in the
file is NXDOMAIN. Over UDP, an answer longer than 300 bytes is sent cut
short (TC), so the client asks again over TCP -- as a real server does with
answers too long for its UDP size.
"""
import socket, struct, sys, threading

KINDS = {'A': 1, 'MX': 15, 'TXT': 16, 'AAAA': 28, 'SRV': 33}
zone = {}
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.rstrip('\n')
    if not line.strip() or line.startswith('#'):
        continue
    name, _, rest = line.partition(' ')
    kind, _, data = rest.partition(' ')
    if kind not in KINDS:
        kind, data = 'TXT', rest
    zone.setdefault(name.lower().rstrip('.'), []).append((KINDS[kind], data))


def encode_name(n):
    out = b''
    for label in n.rstrip('.').split('.'):
        if label:
            out += bytes([len(label)]) + label.encode()
    return out + b'\0'


def rdata(kind, data):
    if kind == 1:
        return socket.inet_aton(data)
    if kind == 28:
        return socket.inet_pton(socket.AF_INET6, data)
    if kind == 15:
        pri, host = data.split()
        return struct.pack('>H', int(pri)) + encode_name(host)
    if kind == 33:
        pri, w, port, host = data.split()
        return struct.pack('>HHH', int(pri), int(w), int(port)) + encode_name(host)
    b = data.encode()
    out = b''
    while True:
        out += bytes([min(len(b), 255)]) + b[:255]
        b = b[255:]
        if not b:
            return out


def answer(q, udp):
    ident = q[:2]
    i = 12
    labels = []
    while q[i] != 0:
        n = q[i]
        labels.append(q[i + 1:i + 1 + n].decode())
        i += n + 1
    qtype = struct.unpack('>H', q[i + 1:i + 3])[0]
    question = q[12:i + 5]
    name = '.'.join(labels).lower()
    recs = [r for r in zone.get(name, []) if r[0] == qtype]
    rcode = 0 if name in zone else 3
    body = b''
    for kind, data in recs:
        rd = rdata(kind, data)
        body += b'\xc0\x0c' + struct.pack('>HHIH', kind, 1, 600, len(rd)) + rd
    flags = 0x8180 | rcode
    if udp and len(body) > 300:
        return ident + struct.pack('>HHHHH', flags | 0x0200, 1, 0, 0, 0) + question
    return ident + struct.pack('>HHHHH', flags, 1, len(recs), 0, 0) + question + body


udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(('127.0.0.1', 0))
port = udp.getsockname()[1]
tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tcp.bind(('127.0.0.1', port))
tcp.listen(8)
print(port, flush=True)


def serve_tcp():
    while True:
        c, _ = tcp.accept()
        try:
            n = struct.unpack('>H', c.recv(2))[0]
            q = b''
            while len(q) < n:
                q += c.recv(n - len(q))
            a = answer(q, False)
            c.sendall(struct.pack('>H', len(a)) + a)
        except Exception:
            pass
        c.close()


threading.Thread(target=serve_tcp, daemon=True).start()
while True:
    q, addr = udp.recvfrom(4096)
    try:
        udp.sendto(answer(q, True), addr)
    except Exception:
        pass
