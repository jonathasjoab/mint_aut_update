#!/bin/bash

set -e

USER_NAME=${SUDO_USER:-$USER}
UPDATE_SCRIPT="/usr/local/bin/mint-update.sh"

SERVICE_FILE="/etc/systemd/system/mint-auto-update.service"
TIMER_FILE="/etc/systemd/system/mint-auto-update.timer"
LOG_FILE="/var/log/mint-auto-update.log"

echo "=== Setup automático iniciado para usuário: $USER_NAME ==="

# 1. Criar script de update
cat << 'EOF' > "$UPDATE_SCRIPT"
#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/mint-auto-update.log"
ERROR_LOG="/var/log/mint-auto-update-error.log"
LOCK_FILE="/var/lock/meu-update.lock"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "$(date '+%F %T') [LOCK] Já existe uma execução em andamento." >> "$LOG_FILE"
    exit 1
}

log() {
    echo "$(date '+%F %T') $1" >> "$LOG_FILE"
}

log_error() {
    echo "$(date '+%F %T') [ERROR] $1" >> "$ERROR_LOG"
    echo "$(date '+%F %T') [ERROR] $1" >> "$LOG_FILE"
}

trap 'log_error "Falha inesperada na linha $LINENO com código $?"; exit 1' ERR

section() {
    {
        echo ""
        echo "==============================="
        echo "$1"
        echo "==============================="
    } >> "$LOG_FILE"
}

run_cmd() {
    DESC="$1"
    shift

    section "INÍCIO: $DESC"

    "$@" >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?

    if [ "$EXIT_CODE" -eq 0 ]; then
        log "STATUS: $DESC concluído com SUCESSO"
    else
        log_error "STATUS: $DESC FALHOU (exit code: $EXIT_CODE)"
    fi

    section "FIM: $DESC"
    return $EXIT_CODE
}

section "EXECUÇÃO INICIADA"
log "Início do ciclo de atualização"

# Atualiza índices (APT-GET)
run_cmd "APT-GET UPDATE" apt-get update

# Detecta updates disponíveis
UPDATES_COUNT=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
log "Pacotes atualizáveis encontrados: $UPDATES_COUNT"

if [ "$UPDATES_COUNT" -gt 0 ]; then
    log "Atualizações disponíveis. Iniciando upgrade..."

    run_cmd "APT-GET UPGRADE" apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
    run_cmd "APT-GET AUTOREMOVE" apt-get -y autoremove
else
    log "Nenhuma atualização disponível. Pulando upgrade e autoremove."
fi

log "Fim do ciclo de atualização"
section "EXECUÇÃO FINALIZADA"
EOF

chmod +x "$UPDATE_SCRIPT"

# 2. Criar service systemd
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Atualização automática do sistema Linux Mint
After=network.target

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
Environment=TERM=xterm
ExecStart=$UPDATE_SCRIPT
StandardInput=null
EOF

# 3. Criar timer systemd
cat << EOF > "$TIMER_FILE"
[Unit]
Description=Timer de atualização automática do Linux Mint

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 4. Recarregar systemd e ativar timer
systemctl daemon-reload
systemctl enable --now mint-auto-update.timer

# 5. Criar log file
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# 6. Ativar linger (opcional)
loginctl enable-linger "$USER_NAME" || true

echo "=== Setup concluído com sucesso ==="
echo "Timer ativo: mint-auto-update.timer"
echo "Log: $LOG_FILE"
