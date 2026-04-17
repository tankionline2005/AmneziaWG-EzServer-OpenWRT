#!/bin/sh
# =============================================================================
# AmneziaWG Interface Setup Script for OpenWRT
# =============================================================================
# Автоматически устанавливает пакеты AmneziaWG (если нужно) и создаёт
# интерфейс с одним пиром, firewall-зоной и опциональной podkop-интеграцией.
#
# Переменные окружения для кастомизации:
#   AWG_IFACE      — имя интерфейса         (по умолчанию: awg1)
#   AWG_PORT       — UDP порт               (по умолчанию: 51821)
#   AWG_SERVER_IP  — IP сервера с маской    (по умолчанию: 10.8.2.1/24)
#   AWG_PEER_IP    — IP пира с маской       (по умолчанию: 10.8.2.2/32)
#   AWG_PEER_DESC  — описание пира          (по умолчанию: AmneziaWGPeer)
#   AWG_FW_ZONE    — имя firewall-зоны      (по умолчанию: AmneziaWG)
#   AWG_DNS        — DNS для клиент-конфига (по умолчанию: 192.168.1.1)
# =============================================================================

# НЕ используем set -e глобально — обрабатываем ошибки явно там где нужно

# -----------------------------------------------------------------------------
# Настройки по умолчанию
# -----------------------------------------------------------------------------
IFACE="${AWG_IFACE:-awg1}"
LISTEN_PORT="${AWG_PORT:-51821}"
SERVER_IP="${AWG_SERVER_IP:-10.8.2.1/24}"
PEER_IP="${AWG_PEER_IP:-10.8.2.2/32}"
PEER_DESC="${AWG_PEER_DESC:-AmneziaWGPeer}"
FW_ZONE="${AWG_FW_ZONE:-AmneziaWG}"
CLIENT_DNS="${AWG_DNS:-192.168.1.1}"

# Установщик пакетов AWG (используется только если пакеты не установлены)
AWG_INSTALL_URL="https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh"

# -----------------------------------------------------------------------------
# Вспомогательные функции
# -----------------------------------------------------------------------------
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Генератор случайных чисел
# Совместим с OpenWRT: date +%N может не работать, используем запасные источники
# -----------------------------------------------------------------------------
_make_seed() {
    # Пробуем несколько источников энтропии и конкатенируем
    _s=""
    _s="${_s}$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)"
    _s="${_s}$(cat /proc/uptime 2>/dev/null | tr -d ' .')"
    _s="${_s}$(date +%S%M%H%d%m%Y 2>/dev/null)"
    # Добавляем случайные байты из /dev/urandom если доступен
    _s="${_s}$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | od -An -tu4 | tr -d ' \n')"
    echo "$_s"
}

# Случайное число в диапазоне [min, max]
rand_range() {
    _min=$1
    _max=$2
    awk -v min="$_min" -v max="$_max" -v seed="$(_make_seed)" \
        'BEGIN { srand(seed+0); print int(min + rand() * (max - min + 1)) }'
}

# Генерирует 4 уникальных случайных 32-битных числа за один вызов awk.
# Выводит их через пробел: "H1 H2 H3 H4"
# Один вызов awk — один seed — четыре разных rand() → нет коллизий из-за одинакового seed.
rand_h4() {
    awk -v seed="$(_make_seed)" 'BEGIN {
        srand(seed + 0)
        do { h1 = int(1 + rand() * 4294967294) } while (h1 == 0)
        do { h2 = int(1 + rand() * 4294967294) } while (h2 == h1)
        do { h3 = int(1 + rand() * 4294967294) } while (h3 == h1 || h3 == h2)
        do { h4 = int(1 + rand() * 4294967294) } while (h4 == h1 || h4 == h2 || h4 == h3)
        print h1, h2, h3, h4
    }'
}

# -----------------------------------------------------------------------------
# Проверка наличия необходимых инструментов
# -----------------------------------------------------------------------------
check_requirements() {
    log "Проверка зависимостей..."

    # uci обязателен
    command -v uci > /dev/null 2>&1 || die "uci не найден. Это скрипт для OpenWRT."

    # wget нужен для установки пакетов
    command -v wget > /dev/null 2>&1 || die "wget не найден."
}

# -----------------------------------------------------------------------------
# Проверка и установка пакетов AmneziaWG
# -----------------------------------------------------------------------------
install_packages() {
    log "Проверка установленных пакетов AmneziaWG..."

    # Проверяем наличие всех трёх ключевых пакетов
    _kmod_ok=0
    _tools_ok=0
    _luci_ok=0

    if opkg list-installed 2>/dev/null | grep -q "^kmod-amneziawg "; then
        _kmod_ok=1
    fi
    if opkg list-installed 2>/dev/null | grep -q "^amneziawg-tools "; then
        _tools_ok=1
    fi
    # luci-пакет мог называться по-разному в разных версиях
    if opkg list-installed 2>/dev/null | grep -qE "^(luci-proto-amneziawg|luci-app-amneziawg) "; then
        _luci_ok=1
    fi

    if [ "$_kmod_ok" -eq 1 ] && [ "$_tools_ok" -eq 1 ] && [ "$_luci_ok" -eq 1 ]; then
        log "Все пакеты AmneziaWG уже установлены, установка пропущена."
        # Убеждаемся что awg доступен
        command -v awg > /dev/null 2>&1 || die "Пакеты установлены, но 'awg' не найден в PATH. Попробуйте перезагрузить роутер."
        return
    fi

    # Какие-то пакеты отсутствуют — сообщаем и запускаем установщик
    [ "$_kmod_ok" -eq 0 ] && warn "  kmod-amneziawg    — не установлен"
    [ "$_tools_ok" -eq 0 ] && warn "  amneziawg-tools   — не установлен"
    [ "$_luci_ok"  -eq 0 ] && warn "  luci-*-amneziawg  — не установлен"

    echo ""
    log "Запускаем установщик пакетов AmneziaWG..."
    log "Источник: ${AWG_INSTALL_URL}"
    echo ""

    # Скачиваем установщик во временный файл
    _install_tmp="/tmp/amneziawg-install-$$.sh"
    if ! wget -q -O "$_install_tmp" "$AWG_INSTALL_URL"; then
        rm -f "$_install_tmp"
        die "Не удалось скачать установщик. Проверьте интернет-соединение."
    fi

    if [ ! -s "$_install_tmp" ]; then
        rm -f "$_install_tmp"
        die "Скачанный установщик пустой."
    fi

    chmod +x "$_install_tmp"

    # Запускаем установщик:
    #   - первый "n" — пропустить установку русской локализации
    #   - второй "n" — пропустить configure_amneziawg_interface
    # Вывод установщика идёт прямо в терминал чтобы пользователь видел прогресс
    if ! printf "n\nn\n" | sh "$_install_tmp"; then
        rm -f "$_install_tmp"
        die "Установщик завершился с ошибкой."
    fi

    rm -f "$_install_tmp"

    # Финальная проверка после установки
    command -v awg > /dev/null 2>&1 || die "'awg' не найден после установки. Попробуйте перезагрузить роутер и запустить скрипт снова."

    log "Пакеты AmneziaWG успешно установлены."
}

# -----------------------------------------------------------------------------
# Генерация AmneziaWG headers
# Логика воспроизведена по:
# https://github.com/PavelSibiryakov/awgheaders/blob/main/header-generator.py
# -----------------------------------------------------------------------------
generate_awg_headers() {
    log "Генерация AmneziaWG headers..."

    # Junk packet count: 1..128
    AWG_JC=$(rand_range 1 128)

    # Junk packet min size: 1..1280
    AWG_JMIN=$(rand_range 1 1280)

    # Junk packet max size: jmin..1280
    _jmax_low=$AWG_JMIN
    _jmax_high=1280
    if [ "$_jmax_low" -gt "$_jmax_high" ]; then
        _jmax_high=$_jmax_low
    fi
    AWG_JMAX=$(rand_range "$_jmax_low" "$_jmax_high")

    # S1: init header junk size — 15..150
    AWG_S1=$(rand_range 15 150)

    # S2: response header junk size — 15..150
    AWG_S2=$(rand_range 15 150)

    # H1..H4: уникальные случайные 32-bit числа — генерируем за один вызов awk
    # (единый seed → четыре последовательных rand() → гарантированно разные значения)
    _h_vals=$(rand_h4) || die "Не удалось сгенерировать H-значения."
    AWG_H1=$(echo "$_h_vals" | awk '{print $1}')
    AWG_H2=$(echo "$_h_vals" | awk '{print $2}')
    AWG_H3=$(echo "$_h_vals" | awk '{print $3}')
    AWG_H4=$(echo "$_h_vals" | awk '{print $4}')

    log "  JC=$AWG_JC  JMIN=$AWG_JMIN  JMAX=$AWG_JMAX"
    log "  S1=$AWG_S1  S2=$AWG_S2"
    log "  H1=$AWG_H1  H2=$AWG_H2  H3=$AWG_H3  H4=$AWG_H4"
}

# -----------------------------------------------------------------------------
# Генерация ключей
# -----------------------------------------------------------------------------
generate_keys() {
    log "Генерация ключей сервера..."
    SERVER_PRIVKEY=$(awg genkey) || die "Ошибка генерации приватного ключа сервера."
    SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | awg pubkey) || die "Ошибка генерации публичного ключа сервера."
    [ -n "$SERVER_PRIVKEY" ] || die "Приватный ключ сервера пустой."
    [ -n "$SERVER_PUBKEY"  ] || die "Публичный ключ сервера пустой."
    log "  Server public key: $SERVER_PUBKEY"

    log "Генерация ключей пира..."
    PEER_PRIVKEY=$(awg genkey) || die "Ошибка генерации приватного ключа пира."
    PEER_PUBKEY=$(echo "$PEER_PRIVKEY" | awg pubkey) || die "Ошибка генерации публичного ключа пира."
    PEER_PSK=$(awg genpsk) || die "Ошибка генерации preshared key."
    [ -n "$PEER_PRIVKEY" ] || die "Приватный ключ пира пустой."
    [ -n "$PEER_PUBKEY"  ] || die "Публичный ключ пира пустой."
    [ -n "$PEER_PSK"     ] || die "Preshared key пустой."
    log "  Peer public key:   $PEER_PUBKEY"
}

# -----------------------------------------------------------------------------
# Проверка конфликтов перед настройкой
# -----------------------------------------------------------------------------
check_conflicts() {
    # Проверяем что порт не занят другим интерфейсом
    _conflict_iface=""
    for _sec in $(uci show network 2>/dev/null | grep "\.listen_port='${LISTEN_PORT}'" | cut -d'.' -f2); do
        if [ "$_sec" != "$IFACE" ]; then
            _conflict_iface="$_sec"
            break
        fi
    done

    if [ -n "$_conflict_iface" ]; then
        die "Порт ${LISTEN_PORT} уже используется интерфейсом '${_conflict_iface}'. Укажите другой порт через AWG_PORT=XXXXX."
    fi
}

# -----------------------------------------------------------------------------
# Проверка: интерфейс уже существует?
# -----------------------------------------------------------------------------
check_existing() {
    if uci get "network.${IFACE}" > /dev/null 2>&1; then
        warn "Интерфейс '${IFACE}' уже существует в UCI."
        printf "Перезаписать? [y/N] "
        read -r _answer
        case "$_answer" in
            y|Y)
                log "Удаляем старый интерфейс и пиры..."
                remove_existing
                ;;
            *)
                die "Отменено пользователем."
                ;;
        esac
    fi
}

remove_existing() {
    # Удаляем все пиры интерфейса
    while uci delete "network.@amneziawg_${IFACE}[0]" 2>/dev/null; do :; done
    # Удаляем сам интерфейс
    uci delete "network.${IFACE}" 2>/dev/null || true
    # Сразу коммитим чтобы UCI был в чистом состоянии
    uci commit network 2>/dev/null || true
    log "Старая конфигурация сети удалена."
}

# -----------------------------------------------------------------------------
# Настройка UCI network
# -----------------------------------------------------------------------------
configure_network() {
    log "Настройка сетевого интерфейса '${IFACE}'..."

    uci set "network.${IFACE}=interface"                          || die "uci set network.${IFACE} failed"
    uci set "network.${IFACE}.proto=amneziawg"
    uci set "network.${IFACE}.private_key=${SERVER_PRIVKEY}"
    uci set "network.${IFACE}.listen_port=${LISTEN_PORT}"
    uci set "network.${IFACE}.multipath=off"
    uci add_list "network.${IFACE}.addresses=${SERVER_IP}"

    # AmneziaWG headers
    uci set "network.${IFACE}.awg_jc=${AWG_JC}"
    uci set "network.${IFACE}.awg_jmin=${AWG_JMIN}"
    uci set "network.${IFACE}.awg_jmax=${AWG_JMAX}"
    uci set "network.${IFACE}.awg_s1=${AWG_S1}"
    uci set "network.${IFACE}.awg_s2=${AWG_S2}"
    uci set "network.${IFACE}.awg_h1=${AWG_H1}"
    uci set "network.${IFACE}.awg_h2=${AWG_H2}"
    uci set "network.${IFACE}.awg_h3=${AWG_H3}"
    uci set "network.${IFACE}.awg_h4=${AWG_H4}"

    log "Добавление пира '${PEER_DESC}'..."
    PEER_SEC=$(uci add "network" "amneziawg_${IFACE}") || die "Не удалось создать секцию пира."
    [ -n "$PEER_SEC" ] || die "uci add вернул пустое имя секции."

    uci set "network.${PEER_SEC}.description=${PEER_DESC}"
    uci set "network.${PEER_SEC}.public_key=${PEER_PUBKEY}"
    uci set "network.${PEER_SEC}.private_key=${PEER_PRIVKEY}"
    uci set "network.${PEER_SEC}.preshared_key=${PEER_PSK}"
    uci add_list "network.${PEER_SEC}.allowed_ips=${PEER_IP}"
    uci set "network.${PEER_SEC}.route_allowed_ips=1"
}

# -----------------------------------------------------------------------------
# Forwarding: вспомогательная функция (определена на верхнем уровне)
# -----------------------------------------------------------------------------
check_add_forwarding() {
    _fwd_src="$1"
    _fwd_dst="$2"
    _fwd_exists=0
    _idx=0
    while uci get "firewall.@forwarding[${_idx}]" > /dev/null 2>&1; do
        _fs=$(uci get "firewall.@forwarding[${_idx}].src" 2>/dev/null)
        _fd=$(uci get "firewall.@forwarding[${_idx}].dest" 2>/dev/null)
        if [ "$_fs" = "$_fwd_src" ] && [ "$_fd" = "$_fwd_dst" ]; then
            _fwd_exists=1
            break
        fi
        _idx=$((_idx + 1))
    done

    if [ "$_fwd_exists" -eq 0 ]; then
        log "  Forwarding: ${_fwd_src} -> ${_fwd_dst}"
        uci add firewall forwarding > /dev/null
        uci set "firewall.@forwarding[-1].src=${_fwd_src}"
        uci set "firewall.@forwarding[-1].dest=${_fwd_dst}"
    else
        warn "  Forwarding ${_fwd_src} -> ${_fwd_dst} уже существует, пропускаем."
    fi
}

# -----------------------------------------------------------------------------
# Настройка UCI firewall
# -----------------------------------------------------------------------------
configure_firewall() {
    log "Настройка firewall..."

    # --- Зона ---
    _zone_idx=""
    _idx=0
    while uci get "firewall.@zone[${_idx}]" > /dev/null 2>&1; do
        _name=$(uci get "firewall.@zone[${_idx}].name" 2>/dev/null)
        if [ "$_name" = "$FW_ZONE" ]; then
            _zone_idx=$_idx
            break
        fi
        _idx=$((_idx + 1))
    done

    if [ -n "$_zone_idx" ]; then
        warn "Firewall зона '${FW_ZONE}' уже существует (индекс ${_zone_idx}), обновляем..."
        _zone_sec="@zone[${_zone_idx}]"
    else
        log "Создаём firewall зону '${FW_ZONE}'..."
        uci add firewall zone > /dev/null
        _zone_sec="@zone[-1]"
        uci set "firewall.${_zone_sec}.name=${FW_ZONE}"
        uci set "firewall.${_zone_sec}.input=ACCEPT"
        uci set "firewall.${_zone_sec}.output=ACCEPT"
        uci set "firewall.${_zone_sec}.forward=REJECT"
    fi

    # Добавляем интерфейс в зону только если его там ещё нет
    _iface_in_zone=0
    _existing_networks=$(uci get "firewall.${_zone_sec}.network" 2>/dev/null)
    for _net in $_existing_networks; do
        if [ "$_net" = "$IFACE" ]; then
            _iface_in_zone=1
            break
        fi
    done
    if [ "$_iface_in_zone" -eq 0 ]; then
        uci add_list "firewall.${_zone_sec}.network=${IFACE}"
    else
        warn "  Интерфейс '${IFACE}' уже привязан к зоне '${FW_ZONE}', пропускаем."
    fi

    # --- Правило Allow-<IFACE> ---
    # Имя правила содержит имя интерфейса — нет конфликтов при нескольких AWG-интерфейсах
    _rule_name="Allow-${IFACE}"
    _rule_exists=0
    _idx=0
    while uci get "firewall.@rule[${_idx}]" > /dev/null 2>&1; do
        _rname=$(uci get "firewall.@rule[${_idx}].name" 2>/dev/null)
        _rport=$(uci get "firewall.@rule[${_idx}].dest_port" 2>/dev/null)
        if [ "$_rname" = "$_rule_name" ] && [ "$_rport" = "$LISTEN_PORT" ]; then
            _rule_exists=1
            break
        fi
        _idx=$((_idx + 1))
    done

    if [ "$_rule_exists" -eq 0 ]; then
        log "Добавляем firewall правило '${_rule_name}' (UDP ${LISTEN_PORT})..."
        uci add firewall rule > /dev/null
        uci set "firewall.@rule[-1].name=${_rule_name}"
        uci set "firewall.@rule[-1].src=wan"
        uci set "firewall.@rule[-1].dest_port=${LISTEN_PORT}"
        uci set "firewall.@rule[-1].proto=udp"
        uci set "firewall.@rule[-1].target=ACCEPT"
    else
        warn "Firewall правило '${_rule_name}' (UDP ${LISTEN_PORT}) уже существует, пропускаем."
    fi

    # --- Forwarding ---
    check_add_forwarding "${FW_ZONE}" "lan"
    check_add_forwarding "${FW_ZONE}" "wan"
    check_add_forwarding "lan"        "${FW_ZONE}"
}

# -----------------------------------------------------------------------------
# Сохранение и применение конфигурации
# -----------------------------------------------------------------------------
apply_config() {
    log "Сохраняем конфигурацию UCI..."
    uci commit network  || die "Ошибка uci commit network."
    uci commit firewall || die "Ошибка uci commit firewall."

    log "Перезапускаем сеть..."
    /etc/init.d/network restart || warn "network restart вернул ненулевой код, проверьте интерфейс вручную."

    log "Перезапускаем firewall..."
    /etc/init.d/firewall restart || warn "firewall restart вернул ненулевой код, проверьте firewall вручную."
}

# -----------------------------------------------------------------------------
# Podkop интеграция
# -----------------------------------------------------------------------------
configure_podkop() {
    _watcher_init="/etc/init.d/${IFACE}-mark-watcher"
    _watcher_bin="/usr/local/bin/${IFACE}-mark-watcher.sh"

    echo ""
    printf "[INFO]  Установить скрипты перенаправления трафика из '${IFACE}' в podkop? [y/N] "
    read -r _answer
    case "$_answer" in
        y|Y) ;;
        *) log "Интеграция с podkop пропущена."; return ;;
    esac

    # --- /usr/local/bin/<iface>-mark-watcher.sh ---
    if [ -f "$_watcher_bin" ]; then
        warn "Файл '${_watcher_bin}' уже существует, пропускаем."
    else
        log "Создаём '${_watcher_bin}'..."
        mkdir -p /usr/local/bin || die "Не удалось создать /usr/local/bin."
        cat > "$_watcher_bin" << WATCHER_EOF
#!/bin/sh
MARK="0x00100000"
IFACE="${IFACE}"
TABLE="inet PodkopTable"
CHAIN="mangle"

check_rule() {
    nft list chain \$TABLE \$CHAIN 2>/dev/null | grep -q "\$1.*\$IFACE"
}

apply_rules() {
    logger -t ${IFACE}-watcher "Rules missing — reapplying"
    nft add rule \$TABLE \$CHAIN iifname "\$IFACE" meta mark set \$MARK
    nft add rule \$TABLE \$CHAIN oifname "\$IFACE" meta mark set \$MARK
}

while true; do
    if ! check_rule "iifname" || ! check_rule "oifname"; then
        apply_rules
    fi
    sleep 5
done
WATCHER_EOF
        chmod +x "$_watcher_bin" || die "Не удалось сделать ${_watcher_bin} исполняемым."
        log "  OK: ${_watcher_bin}"
    fi

    # --- /etc/init.d/<iface>-mark-watcher ---
    if [ -f "$_watcher_init" ]; then
        warn "Файл '${_watcher_init}' уже существует, пропускаем."
    else
        log "Создаём init-скрипт '${_watcher_init}'..."
        cat > "$_watcher_init" << INIT_EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command ${_watcher_bin}
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INIT_EOF
        chmod +x "$_watcher_init" || die "Не удалось сделать ${_watcher_init} исполняемым."

        if "$_watcher_init" enable; then
            log "  OK: ${_watcher_init} (добавлен в автозапуск)"
        else
            warn "  ${_watcher_init} создан, но 'enable' завершился с ошибкой — проверьте автозапуск вручную."
        fi
    fi

    log "Интеграция с podkop настроена."
}

# -----------------------------------------------------------------------------
# Вывод итоговой информации + клиентский конфиг
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================================"
    echo "  AmneziaWG — настройка завершена!"
    echo "============================================================"
    echo "  Конфиг для импорта в приложение Amnezia (клиент):"
    echo "============================================================"
    echo ""
    echo "[Interface]"
    echo "PrivateKey = ${PEER_PRIVKEY}"
    echo "Address = ${PEER_IP}"
    echo "DNS = ${CLIENT_DNS}"
    echo "Jc = ${AWG_JC}"
    echo "Jmin = ${AWG_JMIN}"
    echo "Jmax = ${AWG_JMAX}"
    echo "S1 = ${AWG_S1}"
    echo "S2 = ${AWG_S2}"
    echo "H1 = ${AWG_H1}"
    echo "H2 = ${AWG_H2}"
    echo "H3 = ${AWG_H3}"
    echo "H4 = ${AWG_H4}"
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${SERVER_PUBKEY}"
    echo "PresharedKey = ${PEER_PSK}"
    echo "Endpoint = X.X.X.X:${LISTEN_PORT}"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
    echo ""
    echo "============================================================"
    echo "  Замените X.X.X.X на внешний IP адрес вашего роутера."
    echo "============================================================"
}

# -----------------------------------------------------------------------------
# Точка входа
# -----------------------------------------------------------------------------
main() {
    echo ""
    log "=== AmneziaWG Setup Script ==="
    log "Интерфейс: ${IFACE} | Порт: ${LISTEN_PORT} | IP: ${SERVER_IP}"
    echo ""

    check_requirements       # uci, wget доступны?
    install_packages         # пакеты AWG установлены? если нет — ставим
    check_conflicts          # порт не занят другим интерфейсом?
    check_existing           # интерфейс уже есть? спросить перед перезаписью
    generate_awg_headers     # случайные AWG-параметры
    generate_keys            # ключи сервера и пира
    configure_network        # UCI network
    configure_firewall       # UCI firewall
    apply_config             # uci commit + restart
    configure_podkop         # опциональная podkop-интеграция
    print_summary            # итог + клиентский конфиг
}

main "$@"
