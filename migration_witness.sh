#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# КОНФИГУРАЦИЯ (менять здесь)
# ============================================================
SOURCE_HOSTNAME="${SOURCE_HOSTNAME:-source-vm-01}"                  # ожидаемый hostname (как в метаданных GCP)
WITNESS_FILE="${WITNESS_FILE:-/var/tmp/witness.dat}"             # путь к файлу маркеров
CHUNK_SIZE="${CHUNK_SIZE:-4096}"                                 # байт на один чанк
WRITE_INTERVAL="${WRITE_INTERVAL:-0.5}"                          # секунд между записями
HOSTNAME_CHECK_INTERVAL="${HOSTNAME_CHECK_INTERVAL:-1}"          # проверять hostname каждые N записей (1 = каждый раз)
METADATA_URL="${METADATA_URL:-http://169.254.169.254/computeMetadata/v1/instance/hostname}"

# ============================================================
# ПРОИЗВОДНЫЕ
# ============================================================
HEADER_SIZE=64                                             # зарезервировано под SEQ + TS + HOST + \n
PADDING_SIZE=$((CHUNK_SIZE - HEADER_SIZE))
START_TIME=$(date +%s)

# ============================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================

now_ts() {
    date +%s
}

now_hms() {
    date '+%H:%M:%S'
}

log() {
    echo "[$(now_hms)] $*"
}

# ============================================================
# ПОЛУЧЕНИЕ HOSTNAME ЧЕРЕЗ GCP METADATA
# ============================================================
get_metadata_hostname() {
    local hostname
    hostname=$(curl -s -S --connect-timeout 5 --max-time 10 \
        -H "Metadata-Flavor: Google" \
        "$METADATA_URL" 2>/dev/null) || true

    if [ -z "$hostname" ]; then
        return 1
    fi
    echo "$hostname"
    return 0
}

get_metadata_hostname_retry() {
    local hostname
    local attempt=0
    local max_attempts=5
    local delay=1

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        hostname=$(get_metadata_hostname) && break
        log "WARN: metadata endpoint недоступен (попытка ${attempt}/${max_attempts}), повтор через ${delay}с ..." >&2
        sleep "$delay"
        delay=$((delay * 2))
    done

    if [ -z "$hostname" ]; then
        log "ERROR: не удалось получить hostname после ${max_attempts} попыток" >&2
        return 1
    fi
    echo "$hostname"
    return 0
}

# ============================================================
# ФОРМИРОВАНИЕ ЧАНКА
# ============================================================
build_chunk() {
    local seq="$1"
    local ts="$2"
    local hostname="$3"

    local header
    header=$(printf "SEQ:%010d TS:%d HOST:%s" "$seq" "$ts" "$hostname")

    if [ ${#header} -gt $HEADER_SIZE ]; then
        log "ERROR: заголовок (${#header} б) превышает HEADER_SIZE (${HEADER_SIZE} б). Уменьшите hostname или увеличьте HEADER_SIZE." >&2
        return 1
    fi

    printf "%-${HEADER_SIZE}s" "$header"

    if [ "$PADDING_SIZE" -gt 0 ]; then
        dd if=/dev/zero bs="$PADDING_SIZE" count=1 2>/dev/null
    fi
}

# ============================================================
# ОПРЕДЕЛЕНИЕ СТАРТОВОГО SEQ (возобновление после перезапуска)
# ============================================================
get_last_seq_from_file() {
    local file="$1"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo 0
        return
    fi

    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    echo $((size / CHUNK_SIZE))
}

# ============================================================
# ПРОВЕРКА СВОБОДНОГО МЕСТА
# ============================================================
check_disk_space() {
    local file_dir
    file_dir=$(dirname "$WITNESS_FILE")
    mkdir -p "$file_dir"

    local available_kb
    available_kb=$(df -k "$file_dir" | awk 'NR==2 {print $4}')

    local min_kb=$(( (CHUNK_SIZE * 100) / 1024 ))
    if [ "$available_kb" -lt "$min_kb" ]; then
        log "ERROR: недостаточно места на диске в ${file_dir} (доступно ${available_kb}K, нужно хотя бы ${min_kb}K)" >&2
        exit 1
    fi
}

# ============================================================
# TRAP: graceful shutdown
# ============================================================
shutdown_requested=0
last_seq_global=0

handle_signal() {
    shutdown_requested=1
}
trap 'handle_signal' INT TERM

# ============================================================
# ОСНОВНОЙ ЦИКЛ
# ============================================================
write_loop() {
    local seq
    seq=$(get_last_seq_from_file "$WITNESS_FILE")
    seq=$((seq + 1))
    last_seq_global=$((seq - 1))

    log "WITNESS START | chunk_size=${CHUNK_SIZE} interval=${WRITE_INTERVAL}s file=${WITNESS_FILE}"
    log "Resuming from seq=${seq} (${WITNESS_FILE} содержит $((seq - 1)) записей)"

    local write_count=0
    local current_hostname=""
    local first_hostname_check=1

    while [ "$shutdown_requested" -eq 0 ]; do
        # --- проверка hostname ---
        if [ "$first_hostname_check" -eq 1 ] || [ $((write_count % HOSTNAME_CHECK_INTERVAL)) -eq 0 ]; then
            first_hostname_check=0
            current_hostname=$(get_metadata_hostname_retry) || exit 1

            # Сравниваем — hostname от GCP может быть полным (host.c.project.internal),
            # поэтому используем pattern match по началу строки
            if [[ "$current_hostname" != "$SOURCE_HOSTNAME"* ]]; then
                log "HOSTNAME MISMATCH: '${current_hostname}' != '${SOURCE_HOSTNAME}*' — остановка"
                last_seq_global=$((seq - 1))
                break
            fi
        fi

        # --- формирование и запись чанка ---
        local ts
        ts=$(now_ts)
        if ! build_chunk "$seq" "$ts" "$current_hostname" >> "$WITNESS_FILE"; then
            exit 1
        fi

        # --- лог (каждый 10-й или каждый 1-й если интервал большой) ---
        if [ $((seq % 10)) -eq 0 ] || [ "$(echo "$WRITE_INTERVAL >= 1" | bc -l 2>/dev/null || echo 1)" -eq 1 ]; then
            log "SEQ:$(printf "%010d" "$seq") written (host=${current_hostname})"
        fi

        seq=$((seq + 1))
        write_count=$((write_count + 1))
        last_seq_global=$((seq - 1))

        sleep "$WRITE_INTERVAL"
    done

    # --- graceful stop: пишем финальный маркер ---
    local final_ts
    final_ts=$(now_ts)

    if [ "$shutdown_requested" -eq 1 ]; then
        log "Получен сигнал завершения, пишу STOP-маркер ..."
        local stop_chunk
        stop_chunk=$(printf "STOP:%010d TS:%d HOST:%s" "$seq" "$final_ts" "${current_hostname:-unknown}")
        printf "%-${HEADER_SIZE}s" "$stop_chunk" >> "$WITNESS_FILE"
        if [ "$PADDING_SIZE" -gt 0 ]; then
            dd if=/dev/zero bs="$PADDING_SIZE" count=1 2>/dev/null >> "$WITNESS_FILE"
        fi
    fi

    local elapsed
    elapsed=$(($(now_ts) - START_TIME))

    log "WITNESS STOP | last_seq=$(printf "%010d" "$last_seq_global") total_records=${last_seq_global} elapsed=${elapsed}s"
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo "=============================================="
    echo "  Migration Witness — генератор RTO-маркеров"
    echo "=============================================="
    echo "Ожидаемый hostname: ${SOURCE_HOSTNAME}"
    echo "Witness-файл:      ${WITNESS_FILE}"
    echo "Размер чанка:      ${CHUNK_SIZE} б"
    echo "Интервал записи:   ${WRITE_INTERVAL} с"
    echo "Metadata URL:      ${METADATA_URL}"
    echo "=============================================="
    echo ""

    check_disk_space
    write_loop
}

main
