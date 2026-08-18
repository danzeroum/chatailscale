# chatailscale — ChatGPT Privado na sua VPS

Stack turnkey: clone este repositório na VPS, rode **um script** e tenha um chat
estilo ChatGPT rodando em total isolamento de rede — a interface (Open WebUI) e
os PDFs/vetores ficam na sua VPS; só o texto da pergunta vai para a GPU sob
demanda no Modal (Kimi K3) via API OpenAI-compatível.

## Arquitetura

```
Seu PC (Tailscale)                      VPS (Hostinger)
      │                                 ┌──────────────────────────────────────┐
      │  https://vps.tailnet.ts.net     │  tailscale serve ──▶ 127.0.0.1:8080  │
      │ ──────────────────────────────▶ │         │                            │
      │   (só a sua tailnet alcança)    │         ▼                            │
      │                                 │  open-webui (container)              │
      │                                 │    ├──▶ Ollama (embeddings na CPU)   │
      │                                 │    │      nomic-embed-text           │
      │                                 │    │      → PDFs viram vetores AQUI  │
      │                                 │    │                                 │
      │                                 │    └──▶ Modal Labs (GPU, us-west)    │
      │                                 │           Kimi K3 — só recebe texto  │
      │                                 └──────────────────────────────────────┘
```

Decisões de segurança embutidas:

- **Bind em 127.0.0.1**: o Docker ignora regras do UFW (a chain `DOCKER` do
  iptables é avaliada antes do INPUT), então publicar `8080:8080` em `0.0.0.0`
  abriria a porta para a internet mesmo com firewall "deny all". Por isso a
  porta só existe no loopback e quem a expõe é o `tailscale serve`.
- **Sem segredo no git**: a chave do Modal fica no `.env` (ignorado pelo
  `.gitignore`). O compose referencia `${MODAL_API_KEY}`.
- **Reuso do Ollama existente**: se a VPS já tem o container `btv-ollama`
  (ver `danzeroum/infra-state`), o instalador o reutiliza em vez de subir um
  segundo servidor Ollama gastando RAM.
- **Telemetria desligada** com as variáveis oficiais do Open WebUI
  (`ANONYMIZED_TELEMETRY`, `SCARF_NO_ANALYTICS`, `DO_NOT_TRACK`).

## Pré-requisitos

- VPS Ubuntu/Debian com acesso SSH (root **ou** usuário com sudo — o script
  detecta e se adapta; o recomendado é usuário com sudo)
- Conta Tailscale (mesma conta no PC e na VPS)
- Endpoint e chave do Modal (GPU com Kimi K3 já configurada)

## Instalação (é só isso)

```bash
git clone https://github.com/danzeroum/chatailscale.git
cd chatailscale
bash install.sh
```

> **Rodando como root?** Funciona — o script dispensa o `sudo` sozinho e só
> mostra um aviso. O recomendado em produção é um usuário com sudo:
> `adduser btv && usermod -aG sudo,docker btv && su - btv`

O script é idempotente (pode rodar de novo sem quebrar nada) e faz:

1. Instala o Docker (se faltar) e valida o plugin `docker compose`
2. Instala e conecta o Tailscale (mostra o link de autorização, se preciso)
3. Cria o `.env` a partir do `.env.example` e pede a chave do Modal
4. Garante a rede Docker `btv-prod-net`
5. Detecta o `btv-ollama` já existente e o reutiliza; senão, sobe um Ollama
   dedicado deste stack (`chatailscale-ollama`, sem porta pública)
6. Sobe o Open WebUI com bind em `127.0.0.1:8080` (com fallback de registry:
   GHCR → Docker Hub oficial, ver Troubleshooting)
7. Baixa o `nomic-embed-text` (~270 MB) — embeddings de PDF na CPU
8. (Opcional) Configura o UFW **sem derrubar seus sites**: detecta a porta SSH
   real, libera 80/443 para o nginx e o resto só via tailscale0
9. (Opcional) Publica o chat só na tailnet: `tailscale serve`
10. Verifica a saúde do WebUI e imprime a URL `https://....ts.net` de acesso

## Primeiro uso

1. No PC (com o Tailscale ligado), abra a URL impressa no fim da instalação
2. Clique em **Sign Up** e crie a conta de admin (fica só no banco da VPS)
3. Admin Settings → **Documents** → Embedding Model → `nomic-embed-text`
4. No seletor de modelos do chat, escolha o modelo do Modal (Kimi K3)
5. Faça upload de um PDF e pergunte — o texto vira vetor na VPS; só o trecho
   relevante + a pergunta saem (HTTPS) para a GPU do Modal

## Arquivos

| Arquivo | Função |
|---|---|
| `install.sh` | Instalador turnkey (idempotente, aceita root ou sudo) |
| `wipe.sh` | Data wipe: apaga containers, volumes, PDFs e vetores deste stack |
| `docker-compose.yml` | Open WebUI + Ollama opcional (profile `local-ollama`) |
| `.env.example` | Modelo de configuração — copie para `.env` |
| `.gitignore` | Garante que o `.env` nunca vaze para o git |

## Comandos úteis

```bash
docker compose logs -f open-webui     # acompanhar logs
docker compose ps                     # estado dos containers
docker exec btv-ollama ollama list    # modelos disponíveis no Ollama
tailscale serve status                # URL pública da tailnet (como root, sem sudo)
docker compose pull && docker compose up -d   # atualizar imagens
```

## Troubleshooting

**`error from registry: denied` ao baixar a imagem (ghcr.io)**
Quase sempre é credencial expirada do GHCR em `~/.docker/config.json` (comum
em VPS onde já houve `docker login`). O instalador trata sozinho: limpa a
credencial, tenta de novo e, se o GHCR seguir indisponível, baixa a imagem
oficial do Docker Hub (`openwebui/open-webui`) e cria uma tag alias. Manual:

```bash
docker logout ghcr.io && docker pull ghcr.io/open-webui/open-webui:main
# ou o fallback:
docker pull openwebui/open-webui:main
docker tag openwebui/open-webui:main ghcr.io/open-webui/open-webui:main
```

**Porta 8080 já em uso** (`ss -tlnp | grep 8080`)
Mude `WEBUI_PORT` no `.env` e rode `bash install.sh` de novo.

**`tailscale serve` falhou**
Ative HTTPS na tailnet em https://login.tailscale.com/admin/dns (MagicDNS +
HTTPS Certificates) e repita: `tailscale serve --bg http://127.0.0.1:8080`.
Sem o serve, o acesso direto pelo IP da tailnet NÃO funciona (bind em
127.0.0.1) — use túnel SSH a partir do PC:
`ssh -L 8080:127.0.0.1:8080 <usuario>@<vps>` e abra http://localhost:8080.

**WebUI não responde no health check**
Veja os logs: `docker compose logs -f open-webui`. Na primeira subida a
imagem tem ~1–2 GB e a inicialização pode levar alguns minutos.

## Data wipe (fim de contrato)

```bash
bash wipe.sh
```

Destrói containers e volumes **deste stack** (banco do Open WebUI, PDFs,
vetores) e remove o `tailscale serve`. Não toca no `btv-ollama` nem em outros
projetos da VPS. O modelo `nomic-embed-text` é genérico e não contém dados de
cliente.

## Avisos de privacidade (LGPD)

- O endpoint do Modal roda em `us-west` (EUA): enviar trechos de documentos é
  transferência internacional de dados. Avalie a base legal e, se houver dados
  pessoais, mascare PII antes de consultar.
- "Zero Data Retention" depende de como o **seu** app no Modal foi escrito
  (sem logs de payload). Não é garantia automática da plataforma — valide.
- Se a chave do Modal já foi colada em chats/tickets em texto claro, rotacione
  no painel do Modal antes de usar em produção.
