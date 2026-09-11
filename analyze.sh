#!/bin/bash
# Сводка по результатам. Считает полноту по каждому типу операции отдельно и
# приводит минимум, медиану и максимум по повторам.
#
# Общего числа «маркеров» здесь нет намеренно: в первом заходе именно оно
# оказалось суммой трёх разнотипных колонок и выдавалось за меру видимости.
set -u

S="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$S/results}"

if [ ! -d "$OUT" ]; then
    echo "нет каталога результатов: $OUT" >&2
    exit 1
fi

envs="host sham gvisor-overlay gvisor-directfs gvisor-gofer qemu-block qemu-virtiofs firecracker-block"

# min/median/max по списку чисел на входе.
stats() {
    sort -n | {
        vals=$(cat)
        n=$(echo "$vals" | grep -c .)
        if [ "$n" = "0" ]; then
            echo "нет"
            return
        fi
        mn=$(echo "$vals" | head -1)
        mx=$(echo "$vals" | tail -1)
        md=$(echo "$vals" | sed -n "$(((n + 1) / 2))p")
        if [ "$mn" = "$mx" ]; then
            echo "$mn"
        else
            echo "$mn/$md/$mx"
        fi
    }
}

# Полнота по типу операции: сколько различных токенов этого типа, записанных
# генератором как успешные, встретилось в трейсе.
recall_for() {
    local trace=$1 truth=$2 op=$3
    local seen=0 total=0 tok
    [ -f "$truth" ] || { echo ""; return; }
    while read -r tok; do
        [ -n "$tok" ] || continue
        total=$((total + 1))
        # -a обязателен: в трейс попадают нулевые байты, grep считает файл
        # двоичным и молча ничего не выводит, а таблица выходит пустой без
        # объяснения причины.
        if grep -qa -- "$tok" "$trace" 2>/dev/null; then
            seen=$((seen + 1))
        fi
    done <<EOF
$(grep "^op=$op " "$truth" 2>/dev/null | grep ' rc=0\| rc=[1-9]' | \
  grep -v 'tok=NOT-INSTRUMENTED' | sed 's/.*tok=//; s/ .*//' | sort -u)
EOF
    [ "$total" = "0" ] && { echo ""; return; }

    # Знаменатель обязан совпадать с тем, что генератор сам объявил успешным.
    # Расхождение означает частичную истину, а на ней полнота выглядит лучше
    # настоящей: делится на меньшее число. Такую строку надо пометить, а не
    # молча посчитать.
    local declared
    declared=$(grep -a "^denom $op " "$truth" 2>/dev/null | sed 's/.*succeeded=//')
    if [ -n "$declared" ] && [ "$declared" != "$total" ]; then
        echo "$seen/$total!"
        return
    fi
    echo "$seen/$total"
}

printf '%-18s %-10s %-9s %-9s %-9s %-9s %-9s\n' \
    среда повторов open write unlink exec connect
printf '%s\n' "--------------------------------------------------------------------------------"

for env in $envs; do
    reps=0; invalid=0; partial=0
    o=""; w=""; u=""; e=""; c=""

    # Расхождение знаменателя с объявленным генератором означает частичную
    # истину. Пометка обязана дойти до таблицы, иначе охранка бесполезна.
    note() {
        case "$1" in *'!'*) partial=1 ;; esac
        echo "$1" | tr -d '!' | cut -d/ -f1
    }
    for f in "$OUT/$env"-*.runid; do
        [ -f "$f" ] || continue
        tag=$(basename "$f" .runid)
        reps=$((reps + 1))
        if [ -f "$OUT/$tag.INVALID" ]; then
            invalid=$((invalid + 1))
            continue
        fi
        tr="$OUT/$tag.trace"; th="$OUT/$tag.truth"
        ro=$(recall_for "$tr" "$th" open)
        rw=$(recall_for "$tr" "$th" write)
        ru=$(recall_for "$tr" "$th" unlink)
        re=$(recall_for "$tr" "$th" exec)
        case "$ro$rw$ru$re" in *'!'*) partial=1 ;; esac
        o="$o$(echo "$ro" | tr -d '!' | cut -d/ -f1)
"
        w="$w$(echo "$rw" | tr -d '!' | cut -d/ -f1)
"
        u="$u$(echo "$ru" | tr -d '!' | cut -d/ -f1)
"
        e="$e$(echo "$re" | tr -d '!' | cut -d/ -f1)
"
        c="$c$(grep -ca '^EVT .* connect ' "$tr" 2>/dev/null; true)
"
    done
    [ "$reps" = "0" ] && continue
    label="$env"
    [ "$invalid" != "0" ] && label="$label*"
    [ "$partial" != "0" ] && label="$label!"
    printf '%-18s %-10s %-9s %-9s %-9s %-9s %-9s\n' "$label" \
        "$((reps - invalid))/$reps" \
        "$(echo "$o" | grep . | stats)" \
        "$(echo "$w" | grep . | stats)" \
        "$(echo "$u" | grep . | stats)" \
        "$(echo "$e" | grep . | stats)" \
        "$(echo "$c" | grep . | stats)"
done

echo
echo "числа это количество различных токенов, дошедших до хоста, из десяти сделанных"
echo "формат min/median/max по повторам; одно число означает совпадение по всем повторам"
echo "звёздочка у имени среды: часть повторов признана негодной, см. файлы *.INVALID"
echo "восклицательный знак: истина частичная, знаменатель меньше объявленного генератором"
echo "read не инструментирован: аргумент вызова это дескриптор, а не путь"

n_invalid=$(ls "$OUT"/*.INVALID 2>/dev/null | wc -l)
n_notruth=$(ls "$OUT"/*.NOTRUTH 2>/dev/null | wc -l)
n_drops=$(grep -l . "$OUT"/*.drops 2>/dev/null | wc -l)
echo
echo "негодных повторов: $n_invalid, без истины: $n_notruth, с потерями или предупреждениями: $n_drops"
