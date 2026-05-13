#!/bin/bash

set -e

USER_NAME=${SUDO_USER:-$USER}
UPDATE_SCRIPT="/usr/local/bin/mint-auto-update.sh"

SERVICE_FILE="/etc/systemd/system/mint-auto-update.service"
TIMER_FILE="/etc/systemd/system/mint-auto-update.timer"
LOG_FILE="/var/log/mint-auto-update.log"

echo "=== Setup automático iniciado para usuário: $USER_NAME ==="

# 1. Criar script de update
cat << 'EOF' > "$UPDATE_SCRIPT"
#!/bin/bash

LOG_FILE="/var/log/mint-auto-update.log"
ERROR_LOG="/var/log/mint-auto-update-error.log"

exec 9>/var/lock/meu-update.lock
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
    echo "" >> "$LOG_FILE"
    echo "===============================" >> "$LOG_FILE"
    echo "$1" >> "$LOG_FILE"
    echo "===============================" >> "$LOG_FILE"
}

run_cmd() {
    DESC="$1"
    shift

    section "INÍCIO: $DESC"

    "$@" >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        log "STATUS: $DESC concluído com SUCESSO"
    else
        log_error "STATUS: $DESC FALHOU (exit code: $EXIT_CODE)"
    fi

    section "FIM: $DESC"
    return $EXIT_CODE
}

section "EXECUÇÃO INICIADA"

log "Início do ciclo de atualização"

run_cmd "APT UPDATE" apt-get update
run_cmd "APT UPGRADE" apt-get -y upgrade
run_cmd "APT AUTOREMOVE" apt-get -y autoremove

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
ExecStart=$UPDATE_SCRIPT
EOF

# 3. Criar timer systemd
cat << EOF > "$TIMER_FILE"
[Unit]
Description=Timer de atualização automática do Linux Mint

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
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

# 6. Ativar linger (opcional, mas solicitado)
loginctl enable-linger "$USER_NAME" || true

echo "=== Setup concluído com sucesso ==="
echo "Timer ativo: mint-auto-update.timer"
echo "Log: $LOG_FILE"

