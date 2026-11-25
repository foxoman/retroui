#!/usr/bin/env python3
"""An AI service of the tests' own: OpenAI's chat completions and images, Anthropic's
Messages. It answers by rule, not by thinking:

- a user's message "note: TEXT" -> the tool `add_note` asked with {"text": TEXT}
- "two: A, B" -> `add_note` asked twice in one answer
- "click: NAME" -> the tool `ui_click` asked with {"name": NAME}
- "tool: NAME {JSON}" -> the tool NAME asked with those arguments
- the tools' results back -> "Done: " and the results joined by " | "
- anything else -> "You said: " and the text (and "with a picture" when one came)

A model whose name starts with "reasoner" refuses tools unless asked with reasoning_effort "none"
(as OpenAI's reasoning models do through chat completions).

POST /v1/images/generations and /v1/images/edits answer with a PNG of the size asked (red;
an edit: green), as base64. GET /state: the last request of each address, as JSON.

    python3 aimock.py [port]       (0 or none: any free port, said on the first line)
"""
import base64
import json
import re
import struct
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

last = {}


def png(w, h, rgb):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def decide(msgs):
    """(what the service does: ('text', words) or ('tools', [(name, args)]))"""
    if not msgs:
        return ('text', 'nothing')
    m = msgs[-1]
    if m['role'] == 'tool':
        res = [x['content'] for x in msgs if x['role'] == 'tool' and x.get('round') == m.get('round')]
        return ('text', 'Done: ' + ' | '.join(res))
    t = m['text']
    if t.startswith('note: '):
        return ('tools', [('add_note', {'text': t[6:]})])
    if t.startswith('two: '):
        a, b = [x.strip() for x in t[5:].split(',', 1)]
        return ('tools', [('add_note', {'text': a}), ('add_note', {'text': b})])
    if t.startswith('tool: '):
        name, _, args = t[6:].partition(' ')
        return ('tools', [(name, json.loads(args or '{}'))])
    if t.startswith('click: '):
        return ('tools', [('ui_click', {'name': t[7:]})])
    return ('text', 'You said: ' + t + (' with a picture' if m.get('picture') else ''))


def openai_msgs(body):
    out = []
    rnd = 0
    for m in body['messages']:
        if m['role'] == 'system':
            continue
        if m['role'] == 'tool':
            out.append({'role': 'tool', 'content': m['content'], 'round': rnd})
            continue
        if m['role'] == 'assistant' and m.get('tool_calls'):
            rnd += 1
        c = m.get('content')
        pic = False
        if isinstance(c, list):
            pic = any(p.get('type') == 'image_url' for p in c)
            c = ' '.join(p.get('text', '') for p in c if p.get('type') == 'text')
        out.append({'role': m['role'], 'text': c or '', 'picture': pic})
    return out


def anthropic_msgs(body):
    out = []
    rnd = 0
    for m in body['messages']:
        c = m['content']
        if isinstance(c, str):
            out.append({'role': m['role'], 'text': c})
            continue
        if m['role'] == 'assistant':
            if any(p.get('type') == 'tool_use' for p in c):
                rnd += 1
            out.append({'role': 'assistant', 'text': ' '.join(p.get('text', '') for p in c if p['type'] == 'text')})
            continue
        res = [p for p in c if p.get('type') == 'tool_result']
        if res:
            for p in res:
                out.append({'role': 'tool', 'content': p['content'], 'round': rnd})
        else:
            out.append({'role': 'user', 'text': ' '.join(p.get('text', '') for p in c if p['type'] == 'text'),
                        'picture': any(p.get('type') == 'image' for p in c)})
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == '/state':
            self.reply(200, last)
        else:
            self.reply(404, {'error': {'message': 'no such page'}})

    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0'))
        raw = self.rfile.read(n)
        path = self.path
        if path.endswith('/chat/completions'):
            body = json.loads(raw)
            last['chat'] = body
            last['auth'] = self.headers.get('Authorization', '')
            if (body.get('model', '').startswith('reasoner') and body.get('tools')
                    and body.get('reasoning_effort') != 'none'):
                # (a model that reasons, as OpenAI's newer ones: no function tools through chat
                # completions while it does)
                self.reply(400, {'error': {
                    'message': 'Function tools with reasoning are not supported for ' + body['model'] +
                               ' in /v1/chat/completions. Set reasoning_effort to none, or use /v1/responses.',
                    'type': 'invalid_request_error', 'param': 'reasoning_effort'}})
                return
            kind, what = decide(openai_msgs(body))
            if kind == 'text':
                msg = {'role': 'assistant', 'content': what}
            else:
                msg = {'role': 'assistant', 'content': None, 'tool_calls': [
                    {'id': 'call_%d' % i, 'type': 'function',
                     'function': {'name': nm, 'arguments': json.dumps(a)}} for i, (nm, a) in enumerate(what)]}
            self.reply(200, {'choices': [{'index': 0, 'message': msg}]})
        elif path.endswith('/messages'):
            body = json.loads(raw)
            last['messages'] = body
            last['key'] = self.headers.get('x-api-key', '')
            kind, what = decide(anthropic_msgs(body))
            if kind == 'text':
                content = [{'type': 'text', 'text': what}]
            else:
                content = [{'type': 'text', 'text': 'On it.'}] + [
                    {'type': 'tool_use', 'id': 'toolu_%d' % i, 'name': nm, 'input': a}
                    for i, (nm, a) in enumerate(what)]
            self.reply(200, {'content': content, 'stop_reason': 'tool_use' if kind == 'tools' else 'end_turn'})
        elif path.endswith('/images/generations'):
            body = json.loads(raw)
            last['generations'] = body
            w, h = [int(x) for x in body['size'].split('x')]
            self.reply(200, {'data': [{'b64_json': base64.b64encode(png(w, h, (220, 30, 30))).decode(),
                                       'revised_prompt': 'a picture of ' + body['prompt']}]})
        elif path.endswith('/images/edits'):
            ct = self.headers.get('Content-Type', '')
            m = re.search(r'boundary=(.+)', ct)
            parts = {}
            if m:
                for p in raw.split(b'--' + m.group(1).encode()):
                    nm = re.search(rb'name="([^"]+)"', p)
                    if nm and b'\r\n\r\n' in p:
                        parts[nm.group(1).decode()] = p.split(b'\r\n\r\n', 1)[1][:-2]
            last['edits'] = {k: (v.decode() if k not in ('image', 'mask') else len(v)) for k, v in parts.items()}
            last['edits']['pngs'] = sum(1 for k in ('image', 'mask') if parts.get(k, b'')[:4] == b'\x89PNG')
            w, h = [int(x) for x in parts.get('size', b'1024x1024').decode().split('x')]
            self.reply(200, {'data': [{'b64_json': base64.b64encode(png(w, h, (30, 200, 30))).decode()}]})
        else:
            self.reply(404, {'error': {'message': 'no such address: ' + path}})


port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
srv = ThreadingHTTPServer(('127.0.0.1', port), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
