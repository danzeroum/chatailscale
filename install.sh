#!/usr/bin/env bash
# =============================================================================
# chatailscale — instalador turnkey do "ChatGPT Privado"
#
# Idempotente: pode rodar quantas vezes quiser. O que ele faz:
#   1. Instala o Docker (se faltar) e valida o plugin `docker compose`
#   2. Instala e conecta o Tailscale (a VPS some da internet pública)
#   3. Prepara o .env com a chave do Modal (segredo NUNCA vai para o git)
#   4. Garante a rede Docker btv-prod-net
#   5. Reutiliza o Ollama que JÁ EXISTE na VPS (btv-ollama) ou sobe um dedicado
#   6. Sobe o Open WebUI com bind em 127.0.0.1 — o Docker ignora o UFW
#      (chain DOCKER do iptables passa na frente), então NUNCA publicamos
#      a porta em 0.0.0.0
#   7. Baixa o nomic-embed-text (embeddings de PDF na CPU)
#   8. (Opcional) UFW sem derrubar os sites em produção (80/443 abertos)
#   9. (Opcional) Publica o chat só na tailnet via `tailscale serve`
#  10. Verifica a saúde e imprime a URL de acesso
#
# Funciona como root ou como usuário normal com sudo (detecta sozinho).
# =============================================================================
set -euo pipefail

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; }

cd "$(dirname "$0")"

# ---------- 0. Root ou usuário com sudo? ----------
# O recomendado (menor privilégio) é um usuário normal no grupo sudo.
# Se você administra a VPS como root, o script se adapta e dispensa o sudo.
if [[ $EUID -eq 0 ]]; then
  SUDO=""
  warn "Rodando como root. Funciona, mas o recomendado é um usuário com sudo:"
  warn "  adduser btv && usermod -aG sudo,docker btv && su - btv"
else
  SUDO="sudo"
  sudo -v
fi

# ---------- 1. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker não encontrado — instalando..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO sh /tmp/get-docker.sh
  if [[ -n "$SUDO" ]]; then
    $SUDO usermod -aG docker "$USER"
    warn "Usuário '$USER' entrou no grupo docker — faça logout/login depois para usar sem sudo."
  fi
fi

# Define como chamar o docker nesta sessão (root sempre tem acesso ao socket)
if docker ps >/dev/null 2>&1; then
  DOCKER="docker"
elif [[ -n "$SUDO" ]]; then
  DOCKER="sudo docker"
else
  err "Docker instalado mas inacessível. Verifique: systemctl status docker"
  exit 1
fi
$DOCKER compose version >/dev/null 2>&1 || { err "Plugin 'docker compose' ausente."; exit 1; }
ok "Docker $($DOCKER version --format '{{.Server.Version}}' 2>/dev/null || echo instalado)"

# ---------- 2. Tailscale ----------
if ! command -v tailscale >/dev/null 2>&1; then
  log "Instalando Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
fi
if ! tailscale status >/dev/null 2>&1; then
  log "Conectando à tailnet — abra o link que aparecer abaixo e autorize:"
  $SUDO tailscale up
fi
ok "Tailscale ativo — IP interno $(tailscale ip -4 2>/dev/null || echo '(verifique com: tailscale ip -4)')"

# ---------- 3. .env (segredos fora do git) ----------
[[ -f .env ]] || { cp .env.example .env; log ".env criado a partir do .env.example"; }
# Valida a sintaxe ANTES de carregar: valor com espaço SEM aspas quebra o
# `source` (ex.: WEBUI_NAME=Chat Privado → bash tenta executar "Privado").
if ! (source .env) 2>/dev/null; then
  warn ".env com sintaxe inválida — recriando a partir do .env.example"
  cp .env.example .env
fi
# shellcheck disable=SC1091
source .env
if [[ -z "${MODAL_API_KEY:-}" ]]; then
  warn "MODAL_API_KEY vazia (é a chave da sua GPU no Modal)."
  read -r -s -p "Cole a chave agora (Enter pula e configura depois no .env): " KEY; echo
  if [[ -n "$KEY" ]]; then
    sed -i "s|^MODAL_API_KEY=.*|MODAL_API_KEY=$KEY|" .env
    ok "Chave gravada no .env (não commitado graças ao .gitignore)"
  fi
fi

# ---------- 4. Rede Docker compartilhada ----------
if ! $DOCKER network inspect btv-prod-net >/dev/null 2>&1; then
  log "Criando rede btv-prod-net..."
  $DOCKER network create btv-prod-net >/dev/null
fi
ok "Rede btv-prod-net pronta"

# ---------- 5. Ollama: reutilizar o existente ou subir um dedicado ----------
if $DOCKER ps --format '{{.Names}}' | grep -qx 'btv-ollama'; then
  OLLAMA_CT="btv-ollama"
  OLLAMA_URL="http://btv-ollama:11434"
  PROFILE_ARGS=()
  ok "Reutilizando o container btv-ollama que já roda na VPS"
else
  OLLAMA_CT="chatailscale-ollama"
  OLLAMA_URL="http://ollama:11434"
  PROFILE_ARGS=(--profile local-ollama)
  log "btv-ollama não encontrado — este stack subirá um Ollama dedicado (sem porta pública)"
fi
sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=$OLLAMA_URL|" .env

# ---------- 6. Subir o stack ----------
# Baixa a imagem ANTES do up para tratar falha de registry:
# "error from registry: denied" no ghcr.io quase sempre é credencial expirada
# em ~/.docker/config.json. Estratégia: limpar credencial → tentar de novo →
# fallback para a imagem OFICIAL no Docker Hub (openwebui/open-webui) com tag alias.
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
log "Baixando a imagem do Open WebUI..."
if ! $DOCKER pull "$WEBUI_IMAGE"; then
  warn "Pull do GHCR negado — removendo credencial possivelmente expirada de ghcr.io"
  warn "(se você usa 'docker login ghcr.io' para outros projetos, refaça o login depois)"
  $DOCKER logout ghcr.io >/dev/null 2>&1 || true
  if ! $DOCKER pull "$WEBUI_IMAGE"; then
    warn "GHCR indisponível — fallback para a imagem oficial no Docker Hub"
    $DOCKER pull openwebui/open-webui:main
    $DOCKER tag openwebui/open-webui:main "$WEBUI_IMAGE"
  fi
fi
log "Subindo containers..."
$DOCKER compose ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} up -d
ok "Stack no ar"

# ---------- 7. Modelo de embeddings (leitura de PDFs na CPU) ----------
log "Baixando nomic-embed-text em $OLLAMA_CT (~270 MB, só na 1ª vez)..."
$DOCKER exec "$OLLAMA_CT" ollama pull nomic-embed-text
ok "Embeddings prontos — PDFs viram vetores na VPS, sem sair dela"

# ---------- 8. UFW (opcional, seguro para quem tem sites em produção) ----------
read -r -p "Configurar o firewall UFW agora? [S/n] " RESP; RESP=${RESP:-S}
if [[ "$RESP" =~ ^[Ss]$ ]]; then
  SSH_PORT=$($SUDO ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | grep -oE '[0-9]+$' | head -1)
  SSH_PORT=${SSH_PORT:-22}
  log "Porta SSH detectada: $SSH_PORT"
  $SUDO ufw default deny incoming
  $SUDO ufw default allow outgoing
  $SUDO ufw allow "$SSH_PORT"/tcp comment 'SSH'
  $SUDO ufw allow 80,443/tcp comment 'Sites publicos (nginx)'
  $SUDO ufw allow in on tailscale0 comment 'Tailnet'
  $SUDO ufw --force enable
  ok "UFW ativo: SSH:$SSH_PORT + 80/443 + tailscale0. O WebUI não depende do UFW (bind 127.0.0.1)."
fi

# ---------- 9. Publicar APENAS na tailnet (não-fatal se falhar) ----------
WEBUI_PORT=${WEBUI_PORT:-8080}
read -r -p "Publicar o chat na sua tailnet via tailscale serve? [S/n] " RESP; RESP=${RESP:-S}
if [[ "$RESP" =~ ^[Ss]$ ]]; then
  if $SUDO tailscale serve --bg "http://127.0.0.1:$WEBUI_PORT"; then
    ok "tailscale serve ativo (HTTPS válido no domínio ts.net)"
  else
    warn "tailscale serve falhou. Ative HTTPS na tailnet em:"
    warn "  https://login.tailscale.com/admin/dns  (MagicDNS + HTTPS Certificates)"
    warn "  e depois rode: $SUDO tailscale serve --bg http://127.0.0.1:$WEBUI_PORT"
  fi
fi

# ---------- 10. Verificação ----------
log "Aguardando o Open WebUI responder..."
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$WEBUI_PORT/health" >/dev/null 2>&1 && break
  sleep 2
done
if curl -sf "http://127.0.0.1:$WEBUI_PORT/health" >/dev/null 2>&1; then
  ok "Open WebUI saudável em http://127.0.0.1:$WEBUI_PORT"
else
  warn "WebUI ainda não respondeu — veja os logs: $DOCKER logs open-webui"
fi

echo
ok "Instalação concluída!"
$SUDO tailscale serve status 2>/dev/null || true
echo
echo "No PC (com o Tailscale ligado), abra a URL https acima."
echo "Fallback sem serve: túnel SSH a partir do PC → ssh -L $WEBUI_PORT:127.0.0.1:$WEBUI_PORT <usuario>@<vps>"
echo "Depois: Sign Up → Admin Settings → Documents → Embedding Model → nomic-embed-text"
