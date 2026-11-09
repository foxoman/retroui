# A small XMPP server over a WebSocket (RFC 7395) for tests/web/chatcheck:
# it signs anyone on (SASL PLAIN), gives a contact list of one, and the
# contact answers each message ("echo: ..."). Python's websockets.
#
#   python3 tests/web/xmppws.py PORT

import asyncio, re, sys
import websockets

OPEN = ("<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' from='localhost' id='s1' "
        "version='1.0' xml:lang='en'/>")


async def session(ws, path=None):
    try:
        await talk(ws)
    except websockets.exceptions.ConnectionClosed:
        pass


async def talk(ws):
    authed = False
    jid = "me@localhost/web"
    async for m in ws:
        if m.startswith("<open"):
            await ws.send(OPEN)
            if not authed:
                await ws.send("<stream:features xmlns:stream='http://etherx.jabber.org/streams'>"
                              "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                              "<mechanism>PLAIN</mechanism></mechanisms></stream:features>")
            else:
                await ws.send("<stream:features xmlns:stream='http://etherx.jabber.org/streams'>"
                              "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></stream:features>")
        elif m.startswith("<auth"):
            authed = True
            await ws.send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        elif m.startswith("<iq"):
            ident = re.search(r"id=['\"]([^'\"]*)", m).group(1)
            if "xmpp-bind" in m:
                await ws.send(f"<iq type='result' id='{ident}'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                              f"<jid>{jid}</jid></bind></iq>")
            elif "jabber:iq:roster" in m:
                await ws.send(f"<iq type='result' id='{ident}'><query xmlns='jabber:iq:roster'>"
                              "<item jid='bot@localhost' name='Echo Bot' subscription='both'/></query></iq>")
            else:
                await ws.send(f"<iq type='result' id='{ident}'/>")
        elif m.startswith("<message"):
            body = re.search(r"<body>(.*?)</body>", m, re.S)
            if body:
                await ws.send(f"<message from='bot@localhost/echo' to='{jid}' type='chat' id='e1'>"
                              f"<body>echo: {body.group(1)}</body></message>")
        elif m.startswith("<close"):
            await ws.send("<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>")
            await ws.close()
            return


async def main():
    async with websockets.serve(session, "127.0.0.1", int(sys.argv[1]), subprotocols=["xmpp"]):
        await asyncio.Future()

asyncio.run(main())
