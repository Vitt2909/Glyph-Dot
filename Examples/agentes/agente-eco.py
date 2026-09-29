#!/usr/bin/env python3
"""Agente externo mínimo para o Glyph (protocolo glyph-brain/1).

O glyphd roda este processo e fala com ele por stdin/stdout, uma linha JSON
por mensagem. O agente pensa; quem age é o glyphd, pela política (o que é
irreversível sempre pede aprovação ao usuário).

Configure em casa/config.yaml:

    cerebro:
      principal:
        provider: externo
        nome: eco
        comando: [python3, /caminho/para/Examples/agentes/agente-eco.py]

Troque a função `pensar` pelo seu agente (VK ou qualquer outro).
Só biblioteca padrão.
"""
import json
import sys


def pensar(req):
    """Recebe o pedido e devolve (texto, chamadas de ferramenta)."""
    turns = req.get("turns", [])
    last = turns[-1] if turns else {}
    tools = {t["name"] for t in req.get("tools", [])}

    # Voltou o resultado de uma ferramenta: responde com ele.
    if last.get("role") == "tool_results":
        conteudo = last["results"][0]["content"] if last.get("results") else ""
        return ("achei: " + " ".join(conteudo.split())[:120], [])

    pergunta = last.get("text", "") if last.get("role") == "user" else ""
    # Pede uma busca se a ferramenta existir. O glyphd decide se pode rodar.
    if pergunta.endswith("?") and "web_search" in tools:
        return ("", [{"id": "c1", "name": "web_search", "input": {"query": pergunta}}])
    return ("você disse: " + pergunta[:80], [])


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        if req.get("type") != "brain.request":
            continue
        texto, chamadas = pensar(req)
        reply = {
            "type": "brain.reply",
            "id": req["id"],
            "text": texto,
            "tool_calls": chamadas,
            "stop": "tool_use" if chamadas else "done",
            "usage": {"input_tokens": 0, "output_tokens": 0},
            "model": "eco",
        }
        sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
