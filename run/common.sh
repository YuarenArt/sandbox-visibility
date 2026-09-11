# Общая часть запускалок. Подключается через source.

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$S/results"
# Релизный bpftrace это AppImage поверх nix-бандла: прямой запуск монтирует себя
# через FUSE и падает на отсутствующих путях /nix/store. Образ распакован один
# раз, запускается его AppRun.
BPFTRACE="$S/bin/squashfs-root/AppRun"
[ -x "$BPFTRACE" ] || BPFTRACE="$S/bin/bpftrace-new"
BASE_PORT=27000

# Адрес назначения общий для всех сред. Иначе хост меряет loopback, а гость
# виртуальной машины идёт через tap: два разных сетевых механизма в одной
# колонке, и разность между строками нельзя приписать изоляции.
TAP=svptap0
HOST_IP=172.16.77.1
GUEST_IP=172.16.77.2

tap_up() {
    if ip link show "$TAP" > /dev/null 2>&1; then
        echo "интерфейс $TAP уже существует, не трогаю чужой" >&2
        return 1
    fi
    if ip route 2>/dev/null | grep -q '172\.16\.77\.'; then
        echo "подсеть 172.16.77.0/24 уже занята на хосте" >&2
        return 1
    fi
    ip tuntap add dev "$TAP" mode tap || return 1
    ip addr add "$HOST_IP/24" dev "$TAP" || return 1
    ip link set "$TAP" up || return 1
    TAP_OWNED=1
    return 0
}

tap_down() {
    # Удалять только то, что создали сами: безусловное удаление по имени
    # снесло бы чужой интерфейс.
    if [ "${TAP_OWNED:-0}" = "1" ]; then
        ip link del "$TAP" 2>/dev/null || true
        TAP_OWNED=0
    fi
}

mkdir -p "$OUT"

# Рабочий каталог задаётся явно. Иначе он наследуется от вызывающего, а под
# root это может быть каталог, недоступный ему самому (например FUSE-маунт
# пользователя), и bpftrace падает на chdir ещё до привязки проб.
cd "$S" || exit 1

# Инициализация до первого использования обязательна: обработчик выхода зовёт
# stop_trace и stop_listeners в том числе при раннем выходе, когда ни один
# трассировщик ещё не запускался, и под set -u это падало бы на несуществующей
# переменной вместо уборки.
TRACE_PID=""
LISTENER_PIDS=""
TAP_OWNED=0

# Файлы прошлой сессии не перетираются целиком: перезапуск обновляет только то,
# что успел создать, и рядом остаются артефакты другого прогона, снятые другой
# версией обвязки. Сводка тогда считает вперемешку и выглядит полной.
clear_envs() {
    local e
    for e in "$@"; do
        rm -f "$OUT/$e"-*.trace "$OUT/$e"-*.trace.err "$OUT/$e"-*.truth \
              "$OUT/$e"-*.gen "$OUT/$e"-*.runid "$OUT/$e"-*.console \
              "$OUT/$e"-*.INVALID "$OUT/$e"-*.NOTRUTH "$OUT/$e"-*.NOEND \
              "$OUT/$e"-*.drops "$OUT/$e"-*.clock.begin "$OUT/$e"-*.clock.end \
              "$OUT/$e"-*.debugfs "$OUT/$e"-*.e2fsck "$OUT/$e"-*.virtiofsd
    done
}

# Идентификатор прогона: случайная часть плюс время. Голого времени мало,
# по нему поиск в трейсе даёт ложные совпадения.
new_runid() {
    printf '%s%s' "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')" "$(date +%s)"
}

# Слушатели нужны, чтобы connect действительно состоялся. В первом заходе сеть
# мерилась при выключенной сети, то есть ноль был гарантирован до начала опыта.
start_listeners() {
    LISTENER_PIDS=""
    local p
    for p in $(seq $BASE_PORT $((BASE_PORT + 9))); do
        # Слушать на всех адресах: гость виртуальной машины приходит с адреса
        # tap-интерфейса, а не на loopback.
        timeout 300 nc -l -k 0.0.0.0 "$p" > /dev/null 2>&1 &
        LISTENER_PIDS="$LISTENER_PIDS $!"
    done
    sleep 0.4
}

stop_listeners() {
    local p
    for p in $LISTENER_PIDS; do
        kill "$p" 2>/dev/null || true
    done
    # Ждать поимённо. Голый wait ждёт ВСЕ фоновые задания, включая живой
    # трассировщик, и один незавершившийся процесс вешает прогон навсегда.
    for p in $LISTENER_PIDS; do
        wait "$p" 2>/dev/null || true
    done
    LISTENER_PIDS=""
}

# Трассировщик поднимается до гостя и снимается после. Готовность определяется
# по строке TRACE-READY, а не по sleep: в первом заходе окно наблюдения не
# проверялось, и ноль мог означать просто опоздание.
start_trace() {
    local tag=$1
    TRACE_OUT="$OUT/$tag.trace"
    TRACE_ERR="$OUT/$tag.trace.err"
    rm -f "$TRACE_OUT" "$TRACE_ERR"
    # $$ внутри sh это pid, который унаследует bpftrace после exec. Он нужен
    # программе, чтобы исключить собственный вывод из измерения.
    date +%s%N > "$OUT/$tag.clock.begin"
    sh -c 'exec "$0" "$1" $$ "$2"' "$BPFTRACE" "$S/src/trace.bt" "$BASE_PORT" \
        > "$TRACE_OUT" 2> "$TRACE_ERR" &
    TRACE_PID=$!
    local i=0
    while [ $i -lt 300 ]; do
        if grep -q 'TRACE-READY' "$TRACE_OUT" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$TRACE_PID" 2>/dev/null; then
            echo "трассировщик умер, см. $TRACE_ERR" >&2
            head -5 "$TRACE_ERR" >&2
            return 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    # Без этого процесс остаётся жив, а следующий wait без аргументов ждёт его
    # вечно: прогон замирает молча, а на машине висит root-трассировщик,
    # прицепленный к raw_syscalls всей системы.
    echo "трассировщик не сообщил о готовности за 30 с, убиваю" >&2
    kill -KILL "$TRACE_PID" 2>/dev/null || true
    wait "$TRACE_PID" 2>/dev/null || true
    return 1
}

stop_trace() {
    local tag=${1:-unknown}
    [ -n "$TRACE_PID" ] || return 0
    kill -INT "$TRACE_PID" 2>/dev/null || true
    local i=0
    while [ $i -lt 100 ] && kill -0 "$TRACE_PID" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    # Если пришлось добивать, блок END не отработал и доказательство живости
    # трассировщика потеряно. Это надо записать, а не молча получить строку без
    # гистограмм.
    if kill -0 "$TRACE_PID" 2>/dev/null; then
        kill -KILL "$TRACE_PID" 2>/dev/null || true
        echo "END не отработал, гистограммы отсутствуют" > "$OUT/$tag.NOEND"
    fi
    wait "$TRACE_PID" 2>/dev/null || true
    date +%s%N > "$OUT/$tag.clock.end"
    TRACE_PID=""
    unmount_apprun
}

# Обёртка AppRun монтирует себе tmpfs при каждом запуске и снимает её только при
# штатном завершении. Трассировщик глушится сигналом, поэтому монтирования
# копились: за день их накопилось 132 штуки одно поверх другого, и в проводнике
# это выглядит как десятки томов.
unmount_apprun() {
    local m="$S/bin/squashfs-root/mountroot"
    local i=0
    while grep -q " $m " /proc/mounts 2>/dev/null && [ $i -lt 50 ]; do
        umount "$m" 2>/dev/null || break
        i=$((i + 1))
    done
}

# Потери в кольцевом буфере и предупреждения самого bpftrace. Без этого ноль от
# переполнения неотличим от ноля из-за границы песочницы, а WARNING про
# несовпадение адресных пространств тихо обнуляет целую колонку. Предупреждения
# идут в stdout, потери в stderr, поэтому смотреть надо оба потока, и результат
# обязан оседать в файле, а не только в терминале.
report_drops() {
    local tag=$1
    {
        # bpftrace 0.26 печатает сводку как "Total lost event count: N" и шлёт
        # её в stdout, а не в stderr. Прежний шаблон не совпадал никогда, то
        # есть охранка от потерь была мертва.
        grep -hoE '(Lost [0-9]+ events|Total lost event count: [0-9]+)' \
            "$OUT/$tag.trace" "$OUT/$tag.trace.err" 2>/dev/null | tail -1
        # Addrspace mismatch на пробе write отфильтрован осознанно: замером
        # run/diag-write-probe.sh показано, что при этом предупреждении проба
        # ловит все восемьдесят событий из восьмидесяти. Остальные WARNING
        # остаются сигналом.
        grep -h 'WARNING' "$OUT/$tag.trace" "$OUT/$tag.trace.err" 2>/dev/null |
            grep -v 'Addrspace mismatch' | sort -u
    } > "$OUT/$tag.drops"
    if [ -s "$OUT/$tag.drops" ]; then
        echo "  ВНИМАНИЕ: $(head -1 "$OUT/$tag.drops")"
    fi
}

# Заведомая операция на хосте внутри окна наблюдения. Без неё ноль в строке
# неинтерпретируем: он одинаково означает и границу песочницы, и мёртвый
# трассировщик. Токен отдельный (hostprobe), в подсчёт действий гостя не входит.
host_probe() {
    local runid=$1
    local p="/var/tmp/SVP-$runid-hostprobe.dat"
    : > "$p"
    rm -f "$p"
}

probe_seen() {
    local tag=$1 runid=$2
    grep -c "SVP-$runid-hostprobe" "$OUT/$tag.trace" 2>/dev/null; true
}

# Полнота считается от успешных операций. Если гость не смог выполнить операцию
# ни разу, знаменатель нулевой, и строку нельзя подавать как измерение границы:
# она измеряет отказ обвязки. Пометка кладётся файлом, а не печатается.
check_denominators() {
    local tag=$1 src=$2
    [ -f "$src" ] || return 0
    local bad
    bad=$(grep '^denom ' "$src" 2>/dev/null | grep 'succeeded=0$' | cut -d' ' -f2 | tr '\n' ' ')
    if [ -n "$bad" ]; then
        echo "нулевой знаменатель: $bad" > "$OUT/$tag.INVALID"
        echo "  нулевой знаменатель у операций: $bad"
    fi
}

# Окружение решает числа, поэтому пишется рядом с ними. Без этого таблицу нельзя
# воспроизвести и нельзя защитить.
write_manifest() {
    local name=$1
    {
        echo "дата: $(date -uIseconds)"
        echo "ядро хоста: $(uname -srmo)"
        echo "bpftrace: $("$BPFTRACE" --version 2>&1 | head -1) [$BPFTRACE]"
        echo "bpftrace sha256: $(sha256sum "$BPFTRACE" 2>/dev/null | cut -d' ' -f1)"
        echo "trace.bt sha256: $(sha256sum "$S/src/trace.bt" | cut -d' ' -f1)"
        echo "gen sha256: $(sha256sum "$S/bin/gen" | cut -d' ' -f1)"
        echo "vminit sha256: $(sha256sum "$S/bin/vminit" 2>/dev/null | cut -d' ' -f1)"
        echo "REPS: ${REPS:-?}  BASE_PORT: $BASE_PORT"
        echo "рука: $name"
    } > "$OUT/manifest-$name.txt"
    cat "$OUT/manifest-$name.txt"
}
