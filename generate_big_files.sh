#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# КОНФИГУРАЦИЯ (менять здесь)
# ============================================================
FILE_COUNT=10                        # количество файлов
FILE_SIZE_MB=500                     # размер одного файла в MiB
WRITE_RATE_MBPS=10                   # лимит записи на один файл, MiB/с
OUTPUT_DIR="./generated_files"       # целевая директория
PARALLEL_JOBS=4                      # макс. одновременно создаваемых файлов
FILE_PREFIX="random_data"            # префикс имени файла

# ============================================================
# ПРОИЗВОДНЫЕ ПЕРЕМЕННЫЕ
# ============================================================
FILE_SIZE_BYTES=$((FILE_SIZE_MB * 1024 * 1024))
WRITE_RATE_BPS=$((WRITE_RATE_MBPS * 1024 * 1024))
TOTAL_BYTES=$((FILE_COUNT * FILE_SIZE_BYTES))
START_TIME=$(date +%s)

# ============================================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ============================================================
check_deps() {
    local missing=()
    for cmd in pv dd df; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ОШИБКА: не найдены утилиты: ${missing[*]}" >&2
        echo "Установите их и повторите запуск." >&2
        exit 1
    fi
}

# ============================================================
# ПРОВЕРКА СВОБОДНОГО МЕСТА
# ============================================================
check_disk_space() {
    mkdir -p "$OUTPUT_DIR"
    local available_kb
    available_kb=$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
    local needed_kb=$((TOTAL_BYTES / 1024))

    if [ "$available_kb" -lt "$needed_kb" ]; then
        local avail_mb=$((available_kb / 1024))
        local need_mb=$((needed_kb / 1024))
        echo "ОШИБКА: недостаточно места на диске." >&2
        echo "  Доступно: ${avail_mb} MiB" >&2
        echo "  Требуется: ${need_mb} MiB" >&2
        exit 1
    fi
}

# ============================================================
# TRAP: очистка незавершённых файлов при Ctrl+C
# ============================================================
cleanup_on_interrupt() {
    echo "" >&2
    echo "ПРЕРВАНО. Удаляю незавершённые файлы..." >&2
    local id
    for id in $(seq 1 "$FILE_COUNT"); do
        local f="${OUTPUT_DIR}/${FILE_PREFIX}_${id}.dat"
        [ -f "$f" ] && rm -f "$f"
    done
    echo "Готово." >&2
    exit 130
}
trap 'cleanup_on_interrupt' INT TERM

# ============================================================
# ГЕНЕРАЦИЯ ОДНОГО ФАЙЛА
# ============================================================
generate_file() {
    local id="$1"
    local output_file="${OUTPUT_DIR}/${FILE_PREFIX}_${id}.dat"

    echo "[$(date '+%H:%M:%S')] [файл ${id}/${FILE_COUNT}] Старт (${FILE_SIZE_MB} MiB, лимит ${WRITE_RATE_MBPS} MiB/с) ..."

    local file_start
    file_start=$(date +%s)

    dd if=/dev/urandom bs=1M count="$FILE_SIZE_MB" 2>/dev/null \
        | pv -L "$WRITE_RATE_BPS" -s "$FILE_SIZE_BYTES" \
        | dd of="$output_file" bs=1M 2>/dev/null

    local file_end
    file_end=$(date +%s)
    local elapsed=$((file_end - file_start))

    local actual_size
    actual_size=$(du -m "$output_file" 2>/dev/null | cut -f1)

    echo "[$(date '+%H:%M:%S')] [файл ${id}/${FILE_COUNT}] Готово: ${actual_size} MiB, заняло ${elapsed} сек"
}

# ============================================================
# ОСНОВНОЙ ЦИКЛ С ПАРАЛЛЕЛЬНЫМ ПУЛОМ (FIFO-семафор)
# ============================================================
main() {
    echo "=============================================="
    echo "  Генерация случайных файлов"
    echo "=============================================="
    echo "Файлов:       ${FILE_COUNT}"
    echo "Размер:       ${FILE_SIZE_MB} MiB каждый"
    echo "Лимит записи: ${WRITE_RATE_MBPS} MiB/с на файл"
    echo "Параллельно:  ${PARALLEL_JOBS}"
    echo "Директория:   ${OUTPUT_DIR}"
    echo "Общий объём:  $((TOTAL_BYTES / 1024 / 1024)) MiB"
    echo "=============================================="
    echo ""

    check_deps
    check_disk_space

    local sem_fifo
    sem_fifo=$(mktemp -u /tmp/generate_big_files_sem.XXXXXX)
    mkfifo "$sem_fifo"
    exec 3<>"$sem_fifo"
    rm -f "$sem_fifo"

    local i
    for ((i = 0; i < PARALLEL_JOBS; i++)); do
        echo >&3
    done

    local id
    for id in $(seq 1 "$FILE_COUNT"); do
        read -r _ <&3
        (
            generate_file "$id"
            echo >&3
        ) &
    done
    wait
    exec 3>&-

    local end_time
    end_time=$(date +%s)
    local total_elapsed=$((end_time - START_TIME))

    echo ""
    echo "=============================================="
    echo "  ГОТОВО"
    echo "=============================================="
    echo "Файлов создано: ${FILE_COUNT}"
    echo "Общее время:    ${total_elapsed} сек"
    echo "Директория:     ${OUTPUT_DIR}"
    echo "=============================================="
}

main
