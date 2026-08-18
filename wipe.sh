#!/usr/bin/env bash
# =============================================================================
# wipe.sh — Data Wipe (Privacy by Design)
#
# Destrói TUDO que este stack gravou: containers, banco do Open WebUI,
# PDFs enviados, vetores e o Ollama local deste stack (se foi criado).
# NÃO toca no btv-ollama nem em outros projetos da VPS.
# Funciona como root ou como usuário normal com sudo.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
if docker ps >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="$SUDO docker"; fi

echo "Isso vai APAGAR permanentemente: open-webui (contas, chats, PDFs, vetores)"
echo "e os volumes deste compose (incluindo o Ollama local, se existir)."
read -r -p "Digite 'APAGAR' para confirmar: " C
[[ "$C" == "APAGAR" ]] || { echo "Abortado."; exit 0; }

$DOCKER compose --profile local-ollama down -v
$SUDO tailscale serve reset 2>/dev/null || true

echo
echo "Wipe concluído."
echo "Lembretes:"
echo " - nomic-embed-text baixado no btv-ollama (se reutilizado) é genérico, sem dados de cliente."
echo " - /tmp/rag_uploads (do rag_api.py de outro projeto) não foi tocado."
