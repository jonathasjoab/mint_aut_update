#!/bin/bash

set -euo pipefail

USER_NAME=${SUDO_USER:-$USER}
UPDATE_SCRIPT="/usr/local/bin/mint-update.sh"
SERVICE_FILE="/etc/systemd/system/mint-auto-update.service"
TIMER_FILE="/etc/systemd/system/mint-auto-update.timer"
LOG_FILE="/var/log/mint-auto-update.log"
ERROR_LOG="/var/log/mint-auto-update-error.log"
LOGROTATE_FILE="/etc/logrotate.d/mint-auto-update"

echo "=== Setup automático iniciado para usuário: $USER_NAME ==="

# 1. Criar script de update
cat << 'EOF' > "$UPDATE_SCRIPT"
#!/bin/bash

# Não usar set -e aqui: os erros são tratados explicitamente via run_cmd.
# set -e causaria saída prematura antes do trap ser acionado quando
# run_cmd captura e retorna exit codes não-zero.
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export TERM=xterm

LOG_FILE="/var/log/mint-auto-update.log"
ERROR_LOG="/var/log/mint-auto-update-error.log"
LOCK_FILE="/var/lock/meu-update.lock"

exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "$(date '+%F %T') [LOCK] Já existe uma execução em andamento." >> "$LOG_FILE"
    exit 1
}

log() {
    echo "$(date '+%F %T') $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "$(date '+%F %T') [ERROR] $1" | tee -a "$LOG_FILE" >> "$ERROR_LOG"
}

# CORRIGIDO: fechar o lock (fd 9) antes de sair para garantir liberação
trap 'log_error "Falha inesperada na linha $LINENO com código $?"; exec 9>&-; exit 1' ERR INT TERM

section() {
    {
        echo ""
        echo "==============================="
        echo "$1"
        echo "==============================="
    } | tee -a "$LOG_FILE"
}

# CORRIGIDO: sem set -e no escopo global; run_cmd não precisa de || true
# e o exit code é capturado de forma segura mesmo em falhas.
run_cmd() {
    local DESC="$1"
    shift

    section "INÍCIO: $DESC"

    local EXIT_CODE=0
    "$@" >> "$LOG_FILE" 2>&1 || EXIT_CODE=$?

    if [ "$EXIT_CODE" -eq 0 ]; then
        log "STATUS: $DESC concluído com SUCESSO"
    else
        log_error "STATUS: $DESC FALHOU (exit code: $EXIT_CODE)"
    fi

    section "FIM: $DESC"
    return "$EXIT_CODE"
}

section "EXECUÇÃO INICIADA"
log "Início do ciclo de atualização"

# Atualiza índices — captura falha explicitamente
if ! run_cmd "APT-GET UPDATE" apt-get update; then
    log_error "Falha no apt-get update. Abortando ciclo para evitar resultados incorretos."
    exec 9>&-
    exit 1
fi

# CORRIGIDO: não descartar stderr; logar a falha se apt-get --just-print falhar
UPDATES_COUNT=0
if ! UPDATES_COUNT=$(apt-get --just-print upgrade 2>>"$ERROR_LOG" | grep -c "^Inst"); then
    log_error "Não foi possível verificar atualizações disponíveis."
    exec 9>&-
    exit 1
fi
log "Pacotes atualizáveis encontrados: $UPDATES_COUNT"

if [ "$UPDATES_COUNT" -gt 0 ]; then
    log "Atualizações disponíveis. Iniciando upgrade..."

    # Registrar timestamp antes do upgrade para filtrar o dpkg.log depois
    UPGRADE_START=$(date '+%Y-%m-%d %H:%M:%S')

    run_cmd "APT-GET UPGRADE" apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        upgrade

    # CORRIGIDO: formato real do dpkg.log é:
    #   2024-01-15 10:23:01 upgrade bash:amd64 5.1-6 5.2-1
    # campos: $1=data $2=hora $3=ação $4=pacote $5=versão-anterior $6=versão-nova
    # A comparação de string ($0 >= start) pode ser imprecisa; usar awk com data+hora
    UPGRADED_PKGS=$(awk \
        -v start="$UPGRADE_START" \
        '$3 == "upgrade" && ($1 " " $2) >= start {
            printf "  - %s: %s -> %s\n", $4, $5, $6
        }' \
        /var/log/dpkg.log)

    if [ -n "$UPGRADED_PKGS" ]; then
        log "Pacotes atualizados:"
        while IFS= read -r line; do
            log "$line"
        done <<< "$UPGRADED_PKGS"
    else
        log "Nenhum pacote registrado no dpkg.log desde $UPGRADE_START."
    fi

    run_cmd "APT-GET AUTOREMOVE" apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        autoremove
else
    log "Nenhuma atualização disponível. Pulando upgrade e autoremove."
fi

# Verifica se reinicialização é necessária
if [ -f /var/run/reboot-required ]; then
    log "AVISO: Reinicialização necessária para aplicar as atualizações."
    if [ -f /var/run/reboot-required.pkgs ]; then
        log "Pacotes que requerem reboot: $(tr '\n' ' ' < /var/run/reboot-required.pkgs)"
    fi
else
    log "Reinicialização não necessária."
fi

log "Fim do ciclo de atualização"
section "EXECUÇÃO FINALIZADA"

# Liberar lock explicitamente ao sair normalmente
exec 9>&-
EOF

chmod +x "$UPDATE_SCRIPT"

# 2. Criar service systemd
# NOTA: sem seção [Install] intencionalmente — este serviço é ativado
# exclusivamente pelo timer mint-auto-update.timer, não via systemctl enable.
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=Atualização automática do sistema Linux Mint
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
Environment=TERM=xterm
StandardInput=null
ExecStart=$UPDATE_SCRIPT
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

# 5. Criar arquivos de log com permissões corretas
# CORRIGIDO: inicializar ambos os arquivos de log (inclusive o error log)
touch "$LOG_FILE" "$ERROR_LOG"
chmod 644 "$LOG_FILE" "$ERROR_LOG"

# 6. Criar configuração de logrotate para evitar crescimento indefinido dos logs
# CORRIGIDO: sem logrotate os logs crescem para sempre
cat << EOF > "$LOGROTATE_FILE"
$LOG_FILE $ERROR_LOG {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

# 7. loginctl enable-linger removido: é relevante apenas para user units (~/.config/systemd/user/).
# Este timer está em /etc/systemd/system/ e roda como root, independente de sessão.

echo ""
echo "=== Setup concluído com sucesso ==="
echo "Timer ativo : mint-auto-update.timer"
echo "Log         : $LOG_FILE"
echo "Error log   : $ERROR_LOG"
echo "Logrotate   : $LOGROTATE_FILE"
