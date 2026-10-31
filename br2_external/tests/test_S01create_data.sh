#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# test_S01create_data.sh - banco hermetico de
#   br2_external/board/X6200/linux/rootfs-overlay/etc/init.d/S01create_data
#
# Contrato: iariap/x6200_gui#212 (epica #211). Corre SOLO dentro de un contenedor
# privado y desechable, como root, con userland ARM real (ver README.md de este
# directorio):
#
#   docker run --rm --privileged -v <repo>:/repo:ro -v <lab>:/lab \
#       h212-x6200-data-arm bash /repo/br2_external/tests/test_S01create_data.sh
#
# Aislamiento - nada del banco puede tocar un dispositivo del host ni la SD del
# owner:
#   * antes del primer caso se reemplaza /dev por un tmpfs privado con solo
#     null/zero/random/urandom/tty/console/loop-control (el nodo de la SD del
#     host, si existiera, no existe dentro del contenedor);
#   * cada caso arma una COPIA de una imagen de tarjeta en /lab/card.img y la
#     asocia a un loop device propio;
#   * las particiones se publican como /dev/mmcblk0pN con un loop propio con
#     offset y sizelimit sobre ESA copia: equivalente determinista de lo que udev
#     publica en la radio (en un loop device el kernel re-crea las particiones
#     con otro minor, asi que no se depende de esa numeracion);
#   * los nodos de loop devices que no son del caso se borran del /dev privado,
#     asi las herramientas (blkid -L, parted, mount) solo pueden ver la copia
#     bajo prueba;
#   * al cerrar cada caso (y en el trap EXIT, incluso si aborta) : umount,
#     losetup -d y borrado de todos los nodos.
#
# El S01create_data probado es el archivo del repo sin editar, ejecutado con bash
# en modo POSIX (argv[0] = "sh"), que es lo que hace /bin/sh -> bash en la ROM.
# Las herramientas son las reales (parted 3.5, util-linux 2.38.1, e2fsprogs) y un
# PATH con shims transparentes registra cada invocacion en un journal por caso.

set -u

LAB=${LAB:-/lab}
REPO=${REPO:-/repo}
SCRIPT=${SCRIPT:-$REPO/br2_external/board/X6200/linux/rootfs-overlay/etc/init.d/S01create_data}
FSTAB=${FSTAB:-$REPO/br2_external/board/X6200/linux/rootfs-overlay/etc/fstab}

CARD=$LAB/card.img
OTHER=$LAB/other.img
TEMPLATE=$LAB/template.img
P3DIR=$LAB/p3
KEEP=$LAB/loops.keep
JOURNAL=$LAB/journal.txt
STDOUT=$LAB/stdout.txt
STDERR=$LAB/stderr.txt
RESULTS=$LAB/results.tsv
CONTENT=$LAB/content
SCRATCH=$LAB/scratch
CASES_DIR=$LAB/cases
MNT=/mnt

# Geometria real de sdcard.img (medida sobre el artefacto del assessment #194):
# p1 BOOT vfat en 2048 (+65536 sectores = 32 MiB), p2 rootfs ext4 en 67584
# (+1048576 sectores = 512 MiB), disco de 1116160 sectores (545 MiB).
CARDSZ=1116160
P1_START=2048
P1_END=67583
P2_START=67584
P2_END=1116159
FREE_START=$((P2_END + 1))
ALIGN=2048          # 1 MiB, la alineacion que genimage le da a p1/p2
P3_SECTORS=262144   # 128 MiB: tamano de las imagenes de DATA precompiladas

RC=
CASE=
CASE_DESC=
CASE_BAD=0
CASE_OK=0
TOTAL_BAD=0
LOOP=
LOOPNAME=
OTHER_LOOP=
OTHER_P1=
WATCHER_PID=

declare -A PART_LOOP=()

# --------------------------------------------------------------- salida ------
say() { printf '%s\n' "$*"; }
ok() {
    CASE_OK=$((CASE_OK + 1))
    printf '  ok    %s\n' "$1"
}
bad() {
    CASE_BAD=$((CASE_BAD + 1))
    TOTAL_BAD=$((TOTAL_BAD + 1))
    printf '  FAIL  %s\n' "$1"
}

case_begin() {
    CASE=$1
    CASE_DESC=$2
    CASE_BAD=0
    CASE_OK=0
    RC=
    say ""
    say "== caso $CASE: $CASE_DESC"
    mkdir -p "$CASES_DIR/$CASE"
}

case_end() {
    local verdict=OK
    [ "$CASE_BAD" -eq 0 ] || verdict=FAIL
    cp -f "$JOURNAL" "$CASES_DIR/$CASE/journal.txt" 2>/dev/null || true
    cp -f "$STDOUT" "$CASES_DIR/$CASE/stdout.txt" 2>/dev/null || true
    cp -f "$STDERR" "$CASES_DIR/$CASE/stderr.txt" 2>/dev/null || true
    if [ -f "$CARD" ]; then
        parted -m -s "$CARD" unit s print free >"$CASES_DIR/$CASE/parted.txt" 2>&1
        sfdisk -d "$CARD" >"$CASES_DIR/$CASE/sfdisk.txt" 2>&1
    fi
    printf '%s\t%s\t%s\trc=%s\t%s\n' \
        "$CASE" "$CASE_DESC" \
        "$(awk '{ print $1 }' "$JOURNAL" 2>/dev/null | sort -u | paste -sd, -)" \
        "${RC:-?}" "$verdict" >>"$RESULTS"
    say "   -> $verdict ($CASE_OK ok, $CASE_BAD fail)"
}

# ------------------------------------------------------------- aserciones ----
expect_rc() {
    if [ "${RC:-x}" = "$1" ]; then
        ok "exit=$1"
    else
        bad "exit=${RC:-?} (esperaba $1)"
    fi
}

expect_stdout_exact() {
    if [ "$(cat "$STDOUT")" = "$1" ]; then
        ok "stdout exacto: $1"
    else
        bad "stdout != '$1' (stdout: $(tr '\n' ' ' <"$STDOUT"))"
    fi
}

expect_no_ready() {
    if grep -qF 'DATA ready' "$STDOUT"; then
        bad "imprimio 'DATA ready' en un caso de falla"
    else
        ok "stdout sin 'DATA ready'"
    fi
}

expect_unavailable() {
    if grep -qF 'DATA unavailable:' "$STDERR"; then
        ok "stderr con 'DATA unavailable:'"
    else
        bad "stderr sin 'DATA unavailable:' (stderr: $(tr '\n' ' ' <"$STDERR"))"
    fi
}

expect_stderr() {
    if grep -qF -- "$1" "$STDERR"; then
        ok "stderr: $1"
    else
        bad "stderr sin '$1' (stderr: $(tr '\n' ' ' <"$STDERR"))"
    fi
}

journal_has() {
    if grep -qF -- "$1" "$JOURNAL"; then
        ok "invoco: $1"
    else
        bad "no invoco: $1 (journal: $(tr '\n' ' ' <"$JOURNAL"))"
    fi
}

journal_not_has() {
    if grep -qF -- "$1" "$JOURNAL"; then
        bad "invoco '$1' y no debia (journal: $(tr '\n' ' ' <"$JOURNAL"))"
    else
        ok "no invoco: $1"
    fi
}

journal_no_writes() {
    local t
    for t in 'parted ' 'partprobe ' 'mkfs' 'mke2fs '; do
        journal_not_has "$t"
    done
}

expect_mounted() {  # $1=source $2=type $3=rw|ro
    local line src rest type opts
    line=$(findmnt -n -r -o SOURCE,FSTYPE,OPTIONS --mountpoint "$MNT" 2>/dev/null) || line=""
    if [ -z "$line" ]; then
        bad "$MNT no quedo montado"
        return
    fi
    src=${line%% *}
    rest=${line#* }
    type=${rest%% *}
    opts=${rest#* }
    if [ "$src" = "$1" ]; then ok "$MNT montado desde $1"; else bad "$MNT desde $src (esperaba $1)"; fi
    if [ "$type" = "$2" ]; then ok "$MNT tipo $2"; else bad "$MNT tipo $type (esperaba $2)"; fi
    case ",$opts," in
        *",$3,"*) ok "$MNT $3" ;;
        *) bad "$MNT sin $3 ($opts)" ;;
    esac
}

fs_type() { blkid -o value -s TYPE "$1" 2>/dev/null; }
fs_label() { blkid -o value -s LABEL "$1" 2>/dev/null; }

region_hash() {  # $1=archivo $2=start $3=end
    dd if="$1" bs=512 skip="$2" count="$(( $3 - $2 + 1 ))" status=none 2>/dev/null |
        sha256sum | cut -d' ' -f1
}

expect_region() {  # $1=nombre $2=start $3=end $4=hash esperado
    local h
    h=$(region_hash "$CARD" "$2" "$3")
    if [ "$h" = "$4" ]; then
        ok "region $1 intacta ($h)"
    else
        bad "region $1 cambio: $h != $4"
    fi
}

table_parts() {
    card_parts | awk '{ printf "%s ", $1 }'
}

# --------------------------------------------------------------- nodos -------
isolate_dev() {
    mount -t tmpfs -o mode=755,nosuid tmpfs /dev || return 1
    mknod /dev/null c 1 3
    mknod /dev/zero c 1 5
    mknod /dev/full c 1 7
    mknod /dev/random c 1 8
    mknod /dev/urandom c 1 9
    mknod /dev/tty c 5 0
    mknod /dev/console c 5 1
    chmod 666 /dev/null /dev/zero /dev/random /dev/urandom /dev/tty
    ln -sf /proc/self/fd /dev/fd
    ln -sf /proc/self/fd/0 /dev/stdin
    ln -sf /proc/self/fd/1 /dev/stdout
    ln -sf /proc/self/fd/2 /dev/stderr
    mknod /dev/loop-control c 10 237
    return 0
}

loop_nodes_reset() {
    local i
    for i in $(seq 0 31); do
        [ -b "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i"
    done
    return 0
}

loop_dev() {  # $1=archivo [$2=offset_sectores] [$3=sectores] -> imprime el device
    # El device se reserva con `losetup -f` y se asocia en el acto: pedir el
    # nombre despues por --associated no dice cual es el nuevo (varios loops
    # pueden estar asociados al mismo archivo).
    local file=$1 off=${2:-} cnt=${3:-} dev attempt=0
    loop_nodes_reset
    dev=
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        dev=$(losetup -f 2>/dev/null) || dev=
        [ -n "$dev" ] || continue
        # `losetup -f` puede devolver un indice fuera del rango de nodos creados
        # (el host tiene loops ocupados por otras sesiones): el nodo se crea al
        # vuelo para ese indice, dentro del /dev privado del contenedor.
        if [ ! -b "$dev" ]; then
            mknod "$dev" b 7 "${dev#/dev/loop}" 2>/dev/null || { dev=; continue; }
        fi
        if [ -n "$off" ]; then
            losetup --offset $((off * 512)) --sizelimit $((cnt * 512)) "$dev" "$file" && break
        else
            losetup "$dev" "$file" && break
        fi
        dev=
    done
    [ -n "$dev" ] || return 1
    grep -qxF "$dev" "$KEEP" 2>/dev/null || printf '%s\n' "$dev" >>"$KEEP"
    printf '%s\n' "$dev" >>"$LAB/loops.all"
    printf '%s\n' "$dev"
    return 0
}

drop_keep() {
    # Desasocia TODO lo que el banco haya asociado, segun el archivo KEEP: el
    # watcher corre en un subshell, asi que los loops que crea no se pueden
    # desasociar desde PART_LOOP del proceso padre.
    local list l
    [ -f "$KEEP" ] || return 0
    list=$(sort -u "$KEEP" 2>/dev/null)
    for l in $list; do
        loop_drop "$l"
    done
    : >"$KEEP"
    return 0
}

loop_drop() {  # $1=device
    [ -n "${1:-}" ] || return 0
    # el nodo puede estar oculto: losetup -d necesita poder abrir el device
    [ -b "$1" ] || mknod "$1" b 7 "${1#/dev/loop}" 2>/dev/null || true
    losetup -d "$1" 2>/dev/null || true
    if [ -f "$KEEP" ]; then
        grep -vxF "$1" "$KEEP" >"$KEEP.tmp" 2>/dev/null || true
        mv -f "$KEEP.tmp" "$KEEP" 2>/dev/null || true
    fi
    return 0
}

hide_loop_nodes() {
    # Oculta los nodos /dev/loopN del /dev privado (los devices siguen asociados):
    # asi blkid -L solo puede nombrar los nodos /dev/mmcblk0pN que publica el banco
    # y parted/mount no ven ningun otro dispositivo de bloque.
    local l
    for l in /dev/loop[0-9]*; do
        [ -e "$l" ] && rm -f "$l"
    done
    return 0
}

card_parts() {  # "n start end" de las particiones de la tabla del archivo
    parted -m -s "$CARD" unit s print 2>/dev/null | sed 's/;[[:space:]]*$//' |
        awk -F: '$1 ~ /^[0-9]+$/ && $5 != "free" {
            s = $2; e = $3
            sub(/s$/, "", s); sub(/s$/, "", e)
            print $1, s, e
        }'
}

publish_parts() {
    # Publica o refresca /dev/mmcblk0pN como loop propio con offset y sizelimit
    # sobre la MISMA copia: equivalente determinista de lo que udev publica para
    # las particiones (en un loop device el kernel las re-crea con otro minor, asi
    # que el banco no depende de esa numeracion).
    local n start end dev
    # sin sustitucion de procesos: el /dev privado del banco no tiene /dev/fd
    card_parts >"$LAB/parts.tmp"
    while read -r n start end; do
        [ -n "$n" ] || continue
        if [ -b "/dev/mmcblk0p$n" ] &&
            [ "$(cat "/dev/.h212p$n" 2>/dev/null)" = "$start $end" ]; then
            continue
        fi
        loop_drop "${PART_LOOP[$n]:-}"
        PART_LOOP[$n]=
        dev=$(loop_dev "$CARD" "$start" "$((end - start + 1))") ||
            { bad "no pude mapear la particion $n"; continue; }
        [ -n "$dev" ] || { bad "loop vacio para la particion $n"; continue; }
        PART_LOOP[$n]=$dev
        rm -f "/dev/mmcblk0p$n"
        if mknod "/dev/mmcblk0p$n" b 7 "${dev#/dev/loop}"; then
            printf '%s' "$start $end" >"/dev/.h212p$n"
        else
            bad "no pude crear el nodo de la particion $n"
        fi
    done <"$LAB/parts.tmp"
    hide_loop_nodes
    return 0
}

attach_card() {
    LOOP=$(loop_dev "$CARD") || return 1
    [ -n "$LOOP" ] || return 1
    rm -f /dev/mmcblk0
    mknod /dev/mmcblk0 b 7 "${LOOP#/dev/loop}" || return 1
    publish_parts
    return 0
}

detach_card() {
    local n
    stop_watcher
    umount "$MNT" 2>/dev/null || true
    umount "$SCRATCH" 2>/dev/null || true
    for n in 1 2 3 4; do
        loop_drop "${PART_LOOP[$n]:-}"
        PART_LOOP[$n]=
    done
    [ -n "$LOOP" ] && loop_drop "$LOOP"
    [ -n "$OTHER_LOOP" ] && loop_drop "$OTHER_LOOP"
    [ -n "$OTHER_P1" ] && loop_drop "$OTHER_P1"
    drop_keep
    LOOP=
    LOOPNAME=
    OTHER_LOOP=
    OTHER_P1=
    rm -f /dev/mmcblk0 /dev/mmcblk0p1 /dev/mmcblk0p2 /dev/mmcblk0p3 /dev/mmcblk0p4
    rm -f /dev/mmcblk1 /dev/mmcblk1p1
    rm -f /dev/.h212p1 /dev/.h212p2 /dev/.h212p3 /dev/.h212p4
    : >"$KEEP"
    hide_loop_nodes
    return 0
}

start_watcher() {
    # Publica las particiones nuevas (el kernel/udev lo haria en la radio). Poll
    # con deadline y deteccion barata de cambios de tabla, no una espera fija.
    (
        deadline=$(( $(date +%s) + 30 ))
        last=
        while [ "$(date +%s)" -lt "$deadline" ]; do
            cur=$(dd if="$CARD" bs=512 count=1 status=none 2>/dev/null |
                md5sum | cut -d' ' -f1) || cur=
            if [ "$cur" != "$last" ]; then
                publish_parts
                last=$cur
            fi
            sleep 0.15
        done
    ) &
    WATCHER_PID=$!
}

stop_watcher() {
    if [ -n "$WATCHER_PID" ]; then
        kill "$WATCHER_PID" 2>/dev/null
        wait "$WATCHER_PID" 2>/dev/null
        WATCHER_PID=
    fi
}

run_script() {
    : >"$JOURNAL"
    RC=0
    PATH="$LAB/shim:$PATH" SHIM_JOURNAL="$JOURNAL" "$LAB/sh" "$SCRIPT" start \
        >"$STDOUT" 2>"$STDERR" || RC=$?
}

make_shims() {
    mkdir -p "$LAB/shim"
    local t real
    for t in parted partprobe sfdisk blkid findmnt mount mkfs.ext4 mkfs.vfat mkfs.fat mkfs mke2fs blockdev; do
        real=$(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v "$t" 2>/dev/null) || real=
        [ -n "$real" ] || continue
        {
            printf '#!/bin/bash\n'
            printf 'printf "%%s %%s\\n" "%s" "$*" >> "${SHIM_JOURNAL:?}"\n' "$t"
            printf 'exec "%s" "$@"\n' "$real"
        } >"$LAB/shim/$t"
        chmod 755 "$LAB/shim/$t"
    done
    ln -sf /bin/bash "$LAB/sh"
}

# --------------------------------------------------------- tarjetas de prueba --
make_content() {
    rm -rf "$CONTENT"
    mkdir -p "$CONTENT/backups"
    printf 'params-v1\n' >"$CONTENT/params.db"
    printf 'backup-v1\n' >"$CONTENT/backups/backup.tgz"
    printf 'keep-me\n' >"$CONTENT/keep.bin"
    ln -sf params.db "$CONTENT/link-params"
    chown 1234:5678 "$CONTENT/keep.bin"
    chmod 640 "$CONTENT/keep.bin"
    chown 0:0 "$CONTENT/params.db"
    chmod 644 "$CONTENT/params.db"
}

expect_content_intact() {  # $1 = etiqueta del caso
    if [ "$(cat "$MNT/params.db" 2>/dev/null)" = "params-v1" ]; then
        ok "$1: /mnt/params.db legible e intacto"
    else
        bad "$1: /mnt/params.db no se lee igual"
    fi
    if [ "$(readlink "$MNT/link-params" 2>/dev/null)" = "params.db" ]; then
        ok "$1: symlink /mnt/link-params -> params.db intacto"
    else
        bad "$1: symlink cambiado ($(readlink "$MNT/link-params" 2>/dev/null))"
    fi
    if [ "$(stat -c '%u:%g:%a' "$MNT/keep.bin" 2>/dev/null)" = "1234:5678:640" ]; then
        ok "$1: ids/modo de /mnt/keep.bin intactos (1234:5678:640)"
    else
        bad "$1: ids/modo cambiados ($(stat -c '%u:%g:%a' "$MNT/keep.bin" 2>/dev/null))"
    fi
    if [ -f "$MNT/backups/backup.tgz" ]; then
        ok "$1: /mnt/backups/backup.tgz presente"
    else
        bad "$1: falta /mnt/backups/backup.tgz"
    fi
}

# Imagen de tarjeta de la ROM: p1 BOOT vfat + p2 rootfs ext4, 545 MiB.
make_template() {
    rm -f "$TEMPLATE"
    truncate -s $((CARDSZ * 512)) "$TEMPLATE"
    parted -m -s "$TEMPLATE" mklabel msdos >/dev/null 2>&1 || return 1
    parted -m -s "$TEMPLATE" unit s mkpart primary fat32 "$P1_START" "$P1_END" >/dev/null 2>&1 || return 1
    parted -m -s "$TEMPLATE" unit s mkpart primary ext4 "$P2_START" "$P2_END" >/dev/null 2>&1 || return 1
    local saved=$CARD
    CARD=$TEMPLATE
    attach_card || { CARD=$saved; return 1; }
    mkfs.vfat -n BOOT /dev/mmcblk0p1 >/dev/null 2>&1 || { CARD=$saved; return 1; }
    mke2fs -q -t ext4 -F -m 0 -L rootfs /dev/mmcblk0p2 >/dev/null 2>&1 || { CARD=$saved; return 1; }
    sync
    detach_card
    CARD=$saved
    return 0
}

# Imagenes de DATA precompiladas (128 MiB cada una) para no repetir mkfs por caso.
make_p3_images() {
    mkdir -p "$P3DIR"
    local rc=0
    truncate -s $((P3_SECTORS * 512)) "$P3DIR/ext4-data-content.img"
    mke2fs -q -t ext4 -F -m 0 -L DATA -d "$CONTENT" "$P3DIR/ext4-data-content.img" >/dev/null 2>&1 || rc=1
    truncate -s $((P3_SECTORS * 512)) "$P3DIR/ext4-other-content.img"
    mke2fs -q -t ext4 -F -m 0 -L OTHER -d "$CONTENT" "$P3DIR/ext4-other-content.img" >/dev/null 2>&1 || rc=1
    truncate -s $((P3_SECTORS * 512)) "$P3DIR/ext4-data-empty.img"
    mke2fs -q -t ext4 -F -m 0 -L DATA "$P3DIR/ext4-data-empty.img" >/dev/null 2>&1 || rc=1
    truncate -s $((P3_SECTORS * 512)) "$P3DIR/ext3-data.img"
    mke2fs -q -t ext3 -F -m 0 -L DATA "$P3DIR/ext3-data.img" >/dev/null 2>&1 || rc=1
    # vfat legacy con contenido: se arma sobre un loop propio y se desasocia
    truncate -s $((P3_SECTORS * 512)) "$P3DIR/vfat-data-content.img"
    VFAT_LOOP=$(loop_dev "$P3DIR/vfat-data-content.img") || return 1
    [ -n "$VFAT_LOOP" ] || return 1
    mkfs.vfat -F 32 -n DATA "$VFAT_LOOP" >/dev/null 2>&1 || { loop_drop "$VFAT_LOOP"; return 1; }
    mount "$VFAT_LOOP" "$SCRATCH" || { loop_drop "$VFAT_LOOP"; return 1; }
    printf 'legacy-params\n' >"$SCRATCH/params.db"
    mkdir -p "$SCRATCH/backups"
    printf 'legacy-backup\n' >"$SCRATCH/backups/backup.tgz"
    sync
    umount "$SCRATCH" || rc=1
    loop_drop "$VFAT_LOOP"
    VFAT_LOOP=
    hide_loop_nodes
    return "$rc"
}

new_card() {  # $1 = MiB de tarjeta mas alla de la imagen (0 = tamano exacto)
    local extra=$1
    detach_card
    rm -f "$CARD"
    cp --sparse=always "$TEMPLATE" "$CARD" || return 1
    truncate -s $(( (CARDSZ + extra * 2048) * 512 )) "$CARD" || return 1
    attach_card || return 1
    return 0
}

# Crea (si hace falta) la particion 3 en el tramo final y le escribe una imagen de
# filesystem. Deja en stdout el sector inicial.
preplace_p3() {  # $1=imagen  [$2=sectores]
    local img=$1 sectors=${2:-$P3_SECTORS} start
    start=$(expected_p3_start "$FREE_START")
    if ! card_parts | awk '{ print $1 }' | grep -qx 3; then
        parted -m -s -a none "$CARD" unit s mkpart primary ext4 \
            "${start}s" "$((start + sectors - 1))s" >/dev/null 2>&1 || return 1
        publish_parts
    fi
    dd if="$img" of="$CARD" bs=512 seek="$start" conv=notrunc status=none || return 1
    sync
    publish_parts
    printf '%s\n' "$start"
    return 0
}

add_part() {  # $1=start $2=sectores -> crea la siguiente particion y publica
    local start=$1 sectors=$2
    parted -m -s -a none "$CARD" unit s mkpart primary ext4 \
        "${start}s" "$((start + sectors - 1))s" >/dev/null 2>&1 || return 1
    publish_parts
    return 0
}

put_fs() {  # $1=imagen $2=start
    dd if="$1" of="$CARD" bs=512 seek="$2" conv=notrunc status=none || return 1
    sync
    return 0
}

card_last_sector() { echo $(( CARDSZ + $1 * 2048 - 1 )); }
expected_p3_start() { echo $(( ($1 + ALIGN - 1) / ALIGN * ALIGN )); }

# -------------------------------------------------------------- preflight ----
preflight() {
    say "== preflight del banco"
    local rc=0
    [ "$(id -u)" = "0" ] || { say "FAIL: hay que correr como root dentro del contenedor"; rc=1; }
    [ -f "$SCRIPT" ] || { say "FAIL: no encuentro $SCRIPT"; rc=1; }
    [ -x "$SCRIPT" ] || { say "FAIL: $SCRIPT no es ejecutable"; rc=1; }
    # Limpieza de artefactos de corridas anteriores (se corre como root: los
    # archivos que dejo el contenedor pertenecen a root).
    rm -rf "$CASES_DIR" "$P3DIR" "$LAB/shim" "$CONTENT" "$SCRATCH" 2>/dev/null || true
    rm -f "$CARD" "$TEMPLATE" "$OTHER" "$JOURNAL" "$STDOUT" "$STDERR" "$RESULTS" 2>/dev/null || true
    mkdir -p "$MNT" "$SCRATCH" "$CASES_DIR" "$P3DIR"
    isolate_dev || { say "FAIL: no pude aislar /dev"; rc=1; }
    make_shims
    make_content
    # El fstab de la ROM va al contenedor: el banco prueba el camino integrado
    # (script + fstab), que es donde vivia F-01 (el fstab declara ext4 y una DATA
    # legacy es vfat). El script del PR no depende del fstab; el de la version
    # base si, y con esta linea su falla reproduce la del primer arranque.
    cp -f "$FSTAB" /etc/fstab || { say "FAIL: no pude instalar el fstab de la ROM"; rc=1; }
    say "   /etc/fstab del contenedor: $(grep -c '^/dev/mmcblk0p3' /etc/fstab) entrada(s) para DATA" 
    : >"$RESULTS"
    : >"$KEEP"
    : >"$LAB/loops.all"
    if ls /dev/mmcblk* /dev/loop* >/dev/null 2>&1; then
        say "FAIL: hay nodos de bloque en el /dev privado antes de empezar"
        rc=1
    fi
    local foreign
    foreign=$(blkid -L DATA 2>/dev/null) || foreign=
    if [ -n "$foreign" ]; then
        say "FAIL: el contenedor ve una DATA ajena ($foreign)"; rc=1
    fi
    say "   nodos del /dev privado antes de armar tarjetas: $(ls /dev | paste -sd' ' -)"
    say "   dispositivo con label DATA visible: '${foreign:-ninguno}'"
    make_template || { say "FAIL: no pude armar la imagen de tarjeta"; rc=1; }
    make_p3_images || { say "FAIL: no pude armar las imagenes de DATA"; rc=1; }
    [ "$rc" -eq 0 ] || exit 1
}

# ------------------------------------------------------- checks estaticos ----
static_checks() {
    case_begin estaticos "el script del PR cumple las reglas estaticas del contrato"
    if grep -qE 'fat32' "$SCRIPT"; then
        bad "el script todavia menciona fat32"
    else
        ok "sin 'fat32' en el script"
    fi
    if grep -qE 'mkfs[. -]*(vfat|fat)' "$SCRIPT"; then
        bad "el script todavia invoca un mkfs vfat"
    else
        ok "sin mkfs vfat en el script"
    fi
    if grep -qF 'mkfs.ext4 -F -m 0 -L DATA "$DATA"' "$SCRIPT"; then
        ok "usa exactamente: mkfs.ext4 -F -m 0 -L DATA \$DATA"
    else
        bad "no encuentro 'mkfs.ext4 -F -m 0 -L DATA \"\$DATA\"'"
    fi
    if grep -qF 'mount -t "$data_type" "$DATA" "$MNT"' "$SCRIPT"; then
        ok "monta la DATA existente con -t <tipo real>"
    else
        bad "no encuentro el montaje explicito con el tipo real"
    fi
    if grep -qE '^/dev/mmcblk0p3[[:space:]]+/mnt[[:space:]]+ext4[[:space:]]+rw' "$FSTAB"; then
        ok "fstab sin cambios: /dev/mmcblk0p3 /mnt ext4 rw"
    else
        bad "fstab no declara /dev/mmcblk0p3 /mnt ext4 rw"
    fi
    if [ -x "$SCRIPT" ]; then
        ok "el init script es ejecutable (0755, como el resto de /etc/init.d)"
    else
        bad "el init script no es ejecutable"
    fi
    if "$LAB/sh" -n "$SCRIPT" 2>"$STDERR"; then
        ok "sintaxis ok con bash en modo POSIX (argv[0]=sh, como en la ROM)"
    else
        bad "sh -n fallo: $(cat "$STDERR")"
    fi
    if bash -n "$SCRIPT" 2>"$STDERR"; then
        ok "sintaxis ok con bash -n"
    else
        bad "bash -n fallo: $(cat "$STDERR")"
    fi
    RC=0
    case_end
}

# ------------------------------------------------------------------- casos ---
case_fresh_first_boot() {
    case_begin fresh-first-boot "SD nueva (p1+p2 y 256 MiB al final): crea p3 ext4 y la monta en el primer boot"
    local extra=256 ws we h1 h2
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(expected_p3_start "$FREE_START")
    we=$(card_last_sector "$extra")
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    start_watcher
    run_script
    expect_rc 0
    expect_stdout_exact "DATA ready (ext4)"
    journal_has "parted -m -s -a none /dev/mmcblk0 unit s mkpart primary ext4 ${ws}s ${we}s"
    journal_has "partprobe /dev/mmcblk0"
    journal_has "blockdev --getsize64 /dev/mmcblk0p3"
    journal_has "mkfs.ext4 -F -m 0 -L DATA /dev/mmcblk0p3"
    journal_has "mount -t ext4 /dev/mmcblk0p3 /mnt"
    journal_not_has "mkfs.vfat"
    if [ "$(fs_type /dev/mmcblk0p3)" = "ext4" ]; then ok "p3 quedo ext4 (blkid)"; else bad "p3 tipo $(fs_type /dev/mmcblk0p3)"; fi
    if [ "$(fs_label /dev/mmcblk0p3)" = "DATA" ]; then ok "p3 quedo con label DATA"; else bad "p3 label $(fs_label /dev/mmcblk0p3)"; fi
    expect_mounted /dev/mmcblk0p3 ext4 rw
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    if [ "$(table_parts)" = "1 2 3 " ]; then ok "tabla de la copia: 1 2 3"; else bad "tabla $(table_parts)"; fi
    case_end
}

case_second_boot() {
    case_begin second-boot-idempotent "segundo boot sobre la misma tarjeta: no re-particiona, no formatea, conserva el contenido"
    local h1 h2
    if [ ! -b /dev/mmcblk0p3 ]; then
        bad "no hay p3 del caso anterior"
        case_end
        return
    fi
    printf 'persist-me\n' >"$MNT/marker.txt" 2>/dev/null || bad "no pude escribir el marcador en /mnt"
    sync
    umount "$MNT" 2>/dev/null || bad "no pude desmontar /mnt (reboot simulado)"
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    start_watcher
    run_script
    expect_rc 0
    expect_stdout_exact "DATA ready (ext4)"
    journal_no_writes
    journal_has "mount -t ext4 /dev/mmcblk0p3 /mnt"
    expect_mounted /dev/mmcblk0p3 ext4 rw
    if [ "$(cat "$MNT/marker.txt" 2>/dev/null)" = "persist-me" ]; then
        ok "el contenido escrito en el primer boot sigue en DATA"
    else
        bad "se perdio /mnt/marker.txt"
    fi
    umount "$MNT" 2>/dev/null || true
    # p3 montada: el kernel escribe metadatos de montaje, asi que lo que tiene que
    # quedar igual es el contenido (arriba) y p1/p2; que no hubo mkfs/parted lo dice
    # el journal (journal_no_writes).
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    case_end
}

case_existing_ext4_content() {
    case_begin existing-ext4-content "DATA ext4 existente con contenido, symlink e ids: se monta y no se toca"
    local extra=256 h1 h2 ws
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(preplace_p3 "$P3DIR/ext4-data-content.img") || { bad "no pude poner la DATA ext4"; case_end; return; }
    if [ "$(blkid -o value -s TYPE /dev/mmcblk0p3)" = "ext4" ]; then ok "p3 es ext4 antes del boot"; else bad "p3 no es ext4"; fi
    if [ "$(fs_label /dev/mmcblk0p3)" = "DATA" ]; then ok "p3 con label DATA antes del boot"; else bad "p3 sin label DATA"; fi
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    run_script
    expect_rc 0
    expect_stdout_exact "DATA ready (ext4)"
    journal_no_writes
    journal_has "mount -t ext4 /dev/mmcblk0p3 /mnt"
    expect_mounted /dev/mmcblk0p3 ext4 rw
    expect_content_intact "DATA ext4 existente"
    umount "$MNT" 2>/dev/null || true
    if [ "$(blkid -o value -s TYPE /dev/mmcblk0p3)" = "ext4" ] && [ "$(fs_label /dev/mmcblk0p3)" = "DATA" ]; then
        ok "p3 sigue ext4 con label DATA despues del boot"
    else
        bad "p3 cambio de tipo o label"
    fi
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    case_end
}

case_legacy_vfat() {
    case_begin legacy-vfat-preserved "DATA vfat legacy (tarjeta anterior a la conversion): se monta como vfat y no se toca"
    local extra=256 h3 ws
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(preplace_p3 "$P3DIR/vfat-data-content.img") || { bad "no pude poner la DATA vfat"; case_end; return; }
    h3=$(region_hash "$CARD" "$ws" "$((ws + P3_SECTORS - 1))")
    run_script
    expect_rc 0
    expect_stdout_exact "DATA ready (vfat legacy)"
    journal_no_writes
    journal_has "mount -t vfat /dev/mmcblk0p3 /mnt"
    expect_mounted /dev/mmcblk0p3 vfat rw
    if [ "$(cat "$MNT/params.db" 2>/dev/null)" = "legacy-params" ]; then
        ok "contenido vfat legacy legible en /mnt"
    else
        bad "contenido vfat legacy alterado"
    fi
    umount "$MNT" 2>/dev/null || true
    expect_region "p3 (vfat legacy)" "$ws" "$((ws + P3_SECTORS - 1))" "$h3"
    case_end
}

case_p3_without_label() {
    case_begin p3-without-label "p3 existe sin label DATA: aborta sin mkfs y sin tocar nada"
    local extra=256 h3 ws
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(preplace_p3 "$P3DIR/ext4-other-content.img") || { bad "no pude poner p3"; case_end; return; }
    h3=$(region_hash "$CARD" "$ws" "$((ws + P3_SECTORS - 1))")
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "DATA unavailable: existing partition requires inspection"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    journal_not_has "partprobe"
    umount "$MNT" 2>/dev/null || true
    expect_region "p3 (intacta)" "$ws" "$((ws + P3_SECTORS - 1))" "$h3"
    case_end
}

case_p3_unsupported_fs() {
    case_begin p3-unsupported-fs "p3 con label DATA pero filesystem que no es ext4 ni vfat: pide inspeccion"
    local extra=256 h3 ws
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(preplace_p3 "$P3DIR/ext3-data.img") || { bad "no pude poner p3 ext3"; case_end; return; }
    h3=$(region_hash "$CARD" "$ws" "$((ws + P3_SECTORS - 1))")
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "DATA unavailable: existing partition requires inspection (the filesystem on /dev/mmcblk0p3 is 'ext3')"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    umount "$MNT" 2>/dev/null || true
    expect_region "p3 (ext3, intacta)" "$ws" "$((ws + P3_SECTORS - 1))" "$h3"
    case_end
}

case_label_on_other_device() {
    case_begin label-on-other-device "la etiqueta DATA esta en otro dispositivo: no la usa, no particiona nada"
    local extra=256 h0 h1 h2
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    rm -f "$OTHER"
    truncate -s 64M "$OTHER"
    parted -m -s "$OTHER" mklabel msdos >/dev/null 2>&1
    parted -m -s "$OTHER" unit s mkpart primary fat32 2048 81919 >/dev/null 2>&1
    OTHER_LOOP=$(loop_dev "$OTHER") || { bad "no pude asociar el segundo disco"; case_end; return; }
    [ -n "$OTHER_LOOP" ] || { bad "loop vacio para el segundo disco"; case_end; return; }
    rm -f /dev/mmcblk1
    mknod /dev/mmcblk1 b 7 "${OTHER_LOOP#/dev/loop}" || true
    OTHER_P1=$(loop_dev "$OTHER" 2048 65536) || { bad "no pude mapear la particion del segundo disco"; case_end; return; }
    [ -n "$OTHER_P1" ] || { bad "loop vacio para la particion del segundo disco"; case_end; return; }
    rm -f /dev/mmcblk1p1
    mknod /dev/mmcblk1p1 b 7 "${OTHER_P1#/dev/loop}" || true
    mkfs.vfat -n DATA /dev/mmcblk1p1 >/dev/null 2>&1 || { bad "no pude etiquetar DATA el segundo disco"; case_end; return; }
    hide_loop_nodes
    h0=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h1=$(region_hash "$CARD" "$P2_START" "$P2_END")
    h2=$(region_hash "$CARD" "$FREE_START" "$(card_last_sector "$extra")")
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "DATA unavailable: existing partition requires inspection (the DATA label is on /dev/mmcblk1p1, not on /dev/mmcblk0p3)"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    expect_region p1 "$P1_START" "$P1_END" "$h0"
    expect_region p2 "$P2_START" "$P2_END" "$h1"
    expect_region "tramo libre (sin p3)" "$FREE_START" "$(card_last_sector "$extra")" "$h2"
    case_end
}

case_p3_readonly() {
    case_begin p3-mounted-readonly "p3 con DATA montada read-only: no remonta, no formatea, falla"
    local extra=256 h3 ws
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(preplace_p3 "$P3DIR/ext4-data-content.img") || { bad "no pude poner la DATA ext4"; case_end; return; }
    h3=$(region_hash "$CARD" "$ws" "$((ws + P3_SECTORS - 1))")
    mount -o ro /dev/mmcblk0p3 "$MNT" || { bad "no pude montar DATA en ro"; case_end; return; }
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "is mounted read-only"
    expect_no_ready
    journal_no_writes
    journal_not_has "mount -t ext4"
    expect_mounted /dev/mmcblk0p3 ext4 ro
    expect_content_intact "DATA ro"
    umount "$MNT" 2>/dev/null || true
    expect_region "p3 (intacta)" "$ws" "$((ws + P3_SECTORS - 1))" "$h3"
    case_end
}

case_mount_fails() {
    case_begin mount-fails "el montaje falla (/mnt no es un directorio): falla sin formatear"
    local extra=256 h1 h2 ws
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(preplace_p3 "$P3DIR/ext4-data-content.img") || { bad "no pude poner la DATA ext4"; case_end; return; }
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    rm -rf "$MNT"
    printf 'not-a-directory\n' >"$MNT"
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "cannot mount /dev/mmcblk0p3 (ext4) on /mnt"
    expect_no_ready
    journal_no_writes
    rm -f "$MNT"
    mkdir -p "$MNT"
    if [ -b /dev/mmcblk0p3 ]; then ok "el nodo de p3 sigue ahi"; else bad "p3 desaparecio"; fi
    # p3 sigue siendo la misma DATA ext4 (no se reformateo) y /mnt no quedo montado
    if [ "$(blkid -o value -s TYPE /dev/mmcblk0p3)" = "ext4" ] && [ "$(fs_label /dev/mmcblk0p3)" = "DATA" ]; then
        ok "p3 sigue ext4 con label DATA (no se reformateo)"
    else
        bad "p3 cambio de tipo o label"
    fi
    if findmnt -n -r -o SOURCE,FSTYPE,OPTIONS --mountpoint "$MNT" >/dev/null 2>&1; then
        bad "$MNT quedo montado pese al fallo"
    else
        ok "$MNT no quedo montado"
    fi
    umount "$MNT" 2>/dev/null || true
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    case_end
}

case_partition_table_unreadable() {
    case_begin parted-fails "parted no puede leer la tabla (disco sin tabla; y sin nodo): falla sin escribir"
    local extra=256 h1 h2
    detach_card
    rm -f "$CARD"
    truncate -s $(( (CARDSZ + extra * 2048) * 512 )) "$CARD"
    attach_card || { bad "no pude asociar la tarjeta sin tabla"; case_end; return; }
    start_watcher
    h1=$(region_hash "$CARD" 0 2047)
    h2=$(region_hash "$CARD" "$P1_START" "$P1_END")
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "cannot read the partition table of /dev/mmcblk0"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    expect_region "MBR/primer MiB" 0 2047 "$h1"
    expect_region "region de p1 (sin tabla)" "$P1_START" "$P1_END" "$h2"

    detach_card
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "cannot read the partition table of /dev/mmcblk0"
    expect_no_ready
    journal_not_has "mkpart"
    case_end
}

case_p3_node_missing() {
    case_begin p3-node-never-appears "el kernel nunca publica /dev/mmcblk0p3: crea la particion, no formatea y falla"
    local extra=256 h1 h2 h3
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    h3=$(region_hash "$CARD" "$FREE_START" "$(card_last_sector "$extra")")
    # sin watcher: el nodo de p3 nunca aparece
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "did not appear after creating partition 3"
    expect_no_ready
    journal_has "mkpart"
    journal_has "partprobe"
    journal_not_has "mkfs"
    journal_not_has "blockdev"
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    expect_region "p3 (creada, sin formato)" "$FREE_START" "$(card_last_sector "$extra")" "$h3"
    if [ "$(table_parts)" = "1 2 3 " ]; then
        ok "la tabla quedo con 1 2 3 pero p3 sin filesystem (region en cero)"
    else
        bad "tabla $(table_parts)"
    fi
    case_end
}

case_free_under_64mib() {
    case_begin free-under-64mib "solo 32 MiB libres al final: aborta antes de tocar la tabla"
    local extra=32 h1 h2 h3
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    h3=$(region_hash "$CARD" "$FREE_START" "$(card_last_sector "$extra")")
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "only 32 MiB of aligned free space after /dev/mmcblk0p2, need 64 MiB"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    journal_not_has "partprobe"
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    expect_region "tramo libre" "$FREE_START" "$(card_last_sector "$extra")" "$h3"
    case_end
}

case_no_free_region() {
    case_begin no-free-region "tarjeta del tamano exacto de la imagen (sin tramo libre): aborta sin escribir"
    local h1 h2
    new_card 0 || { bad "no pude armar la tarjeta"; case_end; return; }
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" 0 2047)
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "no free region reaches the end of /dev/mmcblk0"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region "MBR/primer MiB" 0 2047 "$h2"
    case_end
}

case_exact_64mib() {
    case_begin exact-64mib "64 MiB justos al final: el minimo alcanza y DATA se crea"
    local extra=64 ws we h1 h2
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(expected_p3_start "$FREE_START")
    we=$(card_last_sector "$extra")
    h1=$(region_hash "$CARD" "$P1_START" "$P1_END")
    h2=$(region_hash "$CARD" "$P2_START" "$P2_END")
    start_watcher
    run_script
    expect_rc 0
    expect_stdout_exact "DATA ready (ext4)"
    journal_has "mkpart primary ext4 ${ws}s ${we}s"
    journal_has "mkfs.ext4 -F -m 0 -L DATA /dev/mmcblk0p3"
    expect_mounted /dev/mmcblk0p3 ext4 rw
    expect_region p1 "$P1_START" "$P1_END" "$h1"
    expect_region p2 "$P2_START" "$P2_END" "$h2"
    umount "$MNT" 2>/dev/null || true
    case_end
}

case_p4_instead_of_p3() {
    case_begin p4-instead-of-p3 "la tabla tiene p1, p2 y p4 (indice distinto de 3): aborta y no toca p4"
    local extra=256 p4s h4
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    p4s=$((FREE_START + 65536))     # p3 temporal de 32 MiB, p4 despues de ella
    add_part "$FREE_START" 65536 || { bad "no pude crear p3 temporal"; case_end; return; }
    add_part "$p4s" "$P3_SECTORS" || { bad "no pude crear p4"; case_end; return; }
    # se borra la particion 3: queda p1, p2, p4 (el numero real importa)
    parted -m -s "$CARD" rm 3 >/dev/null 2>&1 || { bad "no pude borrar p3"; case_end; return; }
    rm -f /dev/mmcblk0p3 /dev/.h212p3
    loop_drop "${PART_LOOP[3]:-}"
    PART_LOOP[3]=
    publish_parts
    put_fs "$P3DIR/ext4-other-content.img" "$p4s" || { bad "no pude poblar p4"; case_end; return; }
    h4=$(region_hash "$CARD" "$p4s" "$((p4s + P3_SECTORS - 1))")
    if [ "$(table_parts)" = "1 2 4 " ]; then ok "tabla de la copia: 1 2 4"; else bad "tabla $(table_parts)"; fi
    run_script
    expect_rc 1
    expect_unavailable
    expect_stderr "partition 4 already exists on /dev/mmcblk0"
    expect_no_ready
    journal_not_has "mkpart"
    journal_not_has "mkfs"
    expect_region "p4" "$p4s" "$((p4s + P3_SECTORS - 1))" "$h4"
    case_end
}

case_data_on_p3_with_p4() {
    case_begin data-on-p3-with-p4 "DATA valida en p3 con p4 presente: monta p3 y jamas toca p4"
    local extra=256 ws p4s h3 h4
    new_card "$extra" || { bad "no pude armar la tarjeta"; case_end; return; }
    ws=$(expected_p3_start "$FREE_START")
    p4s=$((ws + P3_SECTORS))
    add_part "$ws" "$P3_SECTORS" || { bad "no pude crear p3"; case_end; return; }
    add_part "$p4s" "$P3_SECTORS" || { bad "no pude crear p4"; case_end; return; }
    put_fs "$P3DIR/vfat-data-content.img" "$ws" || { bad "no pude escribir la DATA vfat en p3"; case_end; return; }
    put_fs "$P3DIR/ext4-other-content.img" "$p4s" || { bad "no pude escribir p4"; case_end; return; }
    h3=$(region_hash "$CARD" "$ws" "$((ws + P3_SECTORS - 1))")
    h4=$(region_hash "$CARD" "$p4s" "$((p4s + P3_SECTORS - 1))")
    if [ "$(table_parts)" = "1 2 3 4 " ]; then ok "tabla de la copia: 1 2 3 4"; else bad "tabla $(table_parts)"; fi
    run_script
    expect_rc 0
    expect_stdout_exact "DATA ready (vfat legacy)"
    journal_no_writes
    journal_has "mount -t vfat /dev/mmcblk0p3 /mnt"
    expect_mounted /dev/mmcblk0p3 vfat rw
    if [ "$(cat "$MNT/params.db" 2>/dev/null)" = "legacy-params" ]; then
        ok "contenido de p3 intacto"
    else
        bad "contenido de p3 alterado"
    fi
    umount "$MNT" 2>/dev/null || true
    expect_region "p3 (DATA vfat)" "$ws" "$((ws + P3_SECTORS - 1))" "$h3"
    expect_region "p4 (jamas tocada)" "$p4s" "$((p4s + P3_SECTORS - 1))" "$h4"
    case_end
}

# ----------------------------------------------------------------- cierre ----
summary() {
    detach_card
    say ""
    say "== resumen por caso"
    if [ -f "$RESULTS" ]; then
        awk -F'\t' '/\t/ { printf "%-24s %-5s rc=%-3s %s\n", $1, $5, $4, $3 }' "$RESULTS"
    fi
    local cases=0 fails=0
    if [ -f "$RESULTS" ]; then
        cases=$(awk -F'\t' '/\t/' "$RESULTS" | wc -l)
        fails=$(awk -F'\t' '/\t/ && $5 != "OK"' "$RESULTS" | wc -l)
    fi
    say ""
    say "casos: $cases, con fallas: $fails, checks con FAIL: $TOTAL_BAD"
    # Chequeo por ASOCIACION al archivo, no por el path que imprime `losetup -a`
    # (ese path se trunca y puede ocultar un loop propio que quedo sin desasociar).
    # Se compara contra el log append-only de loops que creo ESTA corrida y se
    # verifica que ya no esten asociados: el path (losetup -a y sysfs lo truncan)
    # y la asociacion por inode (el archivo se recrea por caso) no sirven.
    local l left=
    if [ -f "$LAB/loops.all" ]; then
        for l in $(sort -u "$LAB/loops.all"); do
            [ -s "/sys/block/${l#/dev/}/loop/backing_file" ] && left="$left $l"
        done
    fi
    if [ -z "$left" ]; then
        ok "ningun loop device quedo asociado a los archivos del banco"
    else
        bad "quedaron loops asociados:$left"
    fi
    if [ "$TOTAL_BAD" -eq 0 ]; then
        say "RESULTADO: PASS"
        exit 0
    fi
    say "RESULTADO: FAIL"
    exit 1
}

# Nunca dejar loop devices asociados, ni siquiera si un caso aborta.
trap 'stop_watcher 2>/dev/null; umount "$MNT" 2>/dev/null; umount "$SCRATCH" 2>/dev/null; if [ -f "$KEEP" ]; then while read -r l; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done <"$KEEP"; fi; true' EXIT

preflight
static_checks
case_fresh_first_boot
case_second_boot
case_existing_ext4_content
case_legacy_vfat
case_p3_without_label
case_p3_unsupported_fs
case_label_on_other_device
case_p3_readonly
case_mount_fails
case_partition_table_unreadable
case_p3_node_missing
case_free_under_64mib
case_no_free_region
case_exact_64mib
case_p4_instead_of_p3
case_data_on_p3_with_p4
summary
