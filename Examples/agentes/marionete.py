#!/usr/bin/env python3
"""Um agente externo que só anima o corpo, pelo Glyph Protocol no socket.

Precisa de `agentes_externos: { corpo: true }` no casa/config.yaml.
O agente pode: body.emote, bubble.say e body.goto (ponto ou casa).
Não pode: pedir aprovação, mexer em tarefas, ver o mundo, usar os sinais de
segurança (await, error, alert; cartao, pausa, escudo). Com o freio puxado,
fica mudo.

    python3 Examples/agentes/marionete.py
"""
import datetime
import json
import os
import socket
import time

home = os.environ.get("GLYPH_HOME") or os.path.expanduser("~/Library/Application Support/Glyph")
path = os.path.join(home, "glyphd.sock")
counter = 0


def send(sock, type_, **payload):
    global counter
    counter += 1
    env = {"v": 0, "id": f"m{counter}", "type": type_,
           "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    env.update(payload)
    sock.sendall((json.dumps(env, ensure_ascii=False) + "\n").encode())


with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.connect(path)
    send(s, "hello", role="brain", protocolVersions=[0], capabilities=["puppet"], name="marionete")
    send(s, "body.emote", clip="wave", dot="pulse")
    send(s, "bubble.say", text="oi! sou um agente externo.", durationSec=4)
    time.sleep(4)
    send(s, "body.emote", clip="think", dot="orbit")
    time.sleep(2)
    send(s, "body.goto", target="home")
