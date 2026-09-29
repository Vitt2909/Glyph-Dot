# Segurança

## Como reportar uma falha

**Não abra issue pública.** Use o reporte privado de vulnerabilidades do
GitHub (aba *Security* → *Report a vulnerability*) neste repositório. A
resposta inicial deve vir em até 7 dias.

Inclua: versão/commit, passos para reproduzir, impacto esperado.

## Modelo de ameaças

### O que protegemos

1. **A máquina do usuário** contra ações que ele não quis: apagar, publicar,
   pagar, enviar.
2. **Os dados do usuário**: memória da casa, chaves de API, conteúdo de
   arquivos e do terminal.
3. **A confiança**: o Glyph nunca finge ter feito algo, nunca esconde uma ação.

### Fronteiras

| Fronteira | Ameaça | Defesa |
|---|---|---|
| Socket corpo ↔ cérebro | Outro processo se passa pelo corpo e aprova ações | UID do par + assinatura do app via audit token; `approval.response` só aceito do app assinado (docs/PROTOCOL.md) |
| Socket corpo ↔ cérebro | Outro processo se passa pelo cérebro e pede aprovações falsas | Corpo só conecta ao socket do usuário, em pasta 0700; `approval.request` só aceito do `glyphd` |
| Conteúdo observado → cérebro | **Injeção de prompt** em página, arquivo, saída de terminal | Conteúdo observado entra como `trusted: false`; ações com efeito derivadas dele sempre pedem aprovação; nunca cria objetivo |
| Cérebro → mundo | Ação irreversível autônoma | Trava por classe em código (docs/AUTONOMY.md); `financial` proibida; `destructive` com dupla confirmação |
| Ferramentas MCP | Ferramenta desconhecida com efeito colateral | Entra como `external_effect` até ser classificada |
| `shell` | Escalada, vazamento de ambiente | Sandbox: pastas permitidas, sem `sudo`, ambiente limpo, timeout |
| Disco | Vazamento de segredos | Chaves no Keychain; logs com redação de segredos; casa em 0700 |
| Rede | Telemetria | Nenhuma telemetria. Nada sai da máquina sem o usuário escolher um cérebro na nuvem |

### Freio

Segurar a casa por 1 s ou o atalho global `⌃⌥⌘.` → pausa geral, cancela
tarefas, todos os Glyphs voltam para casa. (M3)

### Permissões do macOS

- M1: **nenhuma**. Limites de janela vêm do `CGWindowList` sem títulos;
  mouse vem de monitor global de `.mouseMoved`.
- Acessibilidade (arrasto suave de janelas) e sensores são opt-in e pedidos
  só quando a função é usada.
- APIs privadas são proibidas no projeto.

## Estado atual

| Defesa | Estado |
|---|---|
| Regras de remetente no protocolo | Implementado e testado (M0) |
| Rejeição de `financial` no protocolo | Implementado e testado (M0) |
| Socket autenticado | M2 |
| Trava de irreversíveis, escada de confiança | M3 |
| Freio global | M3 |
| Keychain, redação de logs | M2 |
