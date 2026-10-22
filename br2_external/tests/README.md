# Tests privados de la imagen X6200

Banco hermetico de scripts de la imagen que **no** se instala en la rootfs (no
vive bajo `rootfs-overlay/`, asi que Buildroot no lo copia al target).

## `test_S01create_data.sh`

Prueba el contrato DATA de `iariap/x6200_gui#212` (epica #211, hallazgos F-01 y
F-18 del assessment #194) sobre el script real
`br2_external/board/X6200/linux/rootfs-overlay/etc/init.d/S01create_data`, sin
editarlo: se lo ejecuta con **bash en modo POSIX** (`argv[0]` = `sh`), que es lo
que hace `/bin/sh -> bash` en la ROM.

### Como se corre

Necesita un contenedor **privado y desechable** con userland ARM (para el
binario real de `bash`/`parted`/`e2fsprogs`) y privilegios para armar loop
devices, nodos de dispositivo y montajes:

```sh
docker build -t h212-x6200-data-arm <dir-con-el-Dockerfile>
docker run --rm --privileged \
    -v <checkout-de-AetherX6200Buildroot>:/repo:ro \
    -v <directorio-de-trabajo-propio>:/lab \
    h212-x6200-data-arm bash /repo/br2_external/tests/test_S01create_data.sh
```

Sale con `0` solo si **todos** los casos pasan. Deja en `/lab` la evidencia cruda:
`results.tsv` (matriz caso -> comandos invocados -> rc -> veredicto), `cases/<caso>/{stdout,stderr,journal,parted,sfdisk}.txt`
y las imagenes de las copias bajo prueba.

Dos variables de entorno sirven para la corrida de contraste (el mismo banco
contra otra version del script): `LAB` (directorio de trabajo, distinto por
corrida) y `SCRIPT` (ruta del script a probar; por defecto el del checkout).

### Que aisla (nunca toca un dispositivo del host ni la SD del owner)

* Reemplaza `/dev` por un tmpfs privado del contenedor con `null`, `zero`,
  `random`, `urandom`, `tty`, `console` y `loop-control`: el nodo de la SD del
  host (si existiera) no existe dentro del contenedor.
* Cada caso arma una **copia** de la imagen de tarjeta en `/lab/card.img`, la
  asocia a un loop device propio (`losetup <device> <archivo>`) y recien entonces
  publica `/dev/mmcblk0` + `/dev/mmcblk0pN` apuntando a las particiones de **esa
  copia**, como lo hace udev en la radio. La geometria copia la real medida del
  artefacto (`p1` BOOT vfat en 2048 +65536 sectores, `p2` rootfs ext4 en 67584
  +1048576 sectores, disco de 1116160 sectores).
* Las particiones se publican con loops con `--offset`/`--sizelimit` sobre esa
  copia y despues se **borran** los nodos `/dev/loopN` del `/dev` privado (los
  devices siguen asociados): asi `blkid -L` solo puede nombrar los nodos
  `/dev/mmcblk0pN` del caso y `parted`/`mount` no ven ningun otro dispositivo de
  bloque. Antes del primer caso el banco verifica que no haya ninguna particion
  con label `DATA` visible.
* El `etc/fstab` de la ROM se copia a `/etc/fstab` del contenedor, para que el
  banco pruebe el camino integrado script+fstab (que es donde vivia F-01).
* Al cerrar cada caso (y en el `trap EXIT`, incluso si un caso aborta): `umount`,
  `losetup -d` y borrado de nodos. El resumen falla si queda algun loop asociado.

### Que mide

Con las herramientas **reales** (`parted` 3.5, util-linux 2.38.1, e2fsprogs) y
un journal que registra cada invocacion del script (shims transparentes que
loguean y ejecutan el binario real):

| Caso | Condicion | Esperado |
| --- | --- | --- |
| `fresh-first-boot` | p1+p2 y 256 MiB libres | crea p3 ext4 (`mkpart` + `mkfs.ext4 -F -m 0 -L DATA`), la monta rw, `DATA ready (ext4)` |
| `second-boot-idempotent` | misma tarjeta, segundo boot | sin `parted`/`mkfs`; monta p3; el contenido del primer boot persiste |
| `existing-ext4-content` | p3 ext4 con contenido, symlink e ids | la monta sin tocar nada: hash de la region y contenido/ids intactos |
| `legacy-vfat-preserved` | p3 vfat legacy con contenido | la monta como vfat (`DATA ready (vfat legacy)`), region intacta |
| `p3-without-label` | p3 sin label DATA | `DATA unavailable: ... requires inspection`, sin mkfs |
| `p3-unsupported-fs` | p3 con label DATA pero ext3 | `DATA unavailable: ... is 'ext3' (existing partition requires inspection)` |
| `label-on-other-device` | label DATA en `/dev/mmcblk1p1` | no la usa, no particiona la tarjeta del ROM |
| `p3-mounted-readonly` | p3 montada ro en `/mnt` | falla; no remonta ni formatea |
| `mount-fails` | `/mnt` no es un directorio | falla sin formatear |
| `parted-fails` | disco sin tabla / sin nodo | falla sin escribir |
| `p3-node-never-appears` | el kernel no publica p3 | crea la particion, no formatea, falla |
| `free-under-64mib` | 32 MiB libres al final | aborta antes de tocar la tabla |
| `no-free-region` | tarjeta del tamano exacto de la imagen | aborta sin escribir |
| `exact-64mib` | 64 MiB justos | el minimo alcanza: crea y monta |
| `p4-instead-of-p3` | tabla 1,2,4 (indice distinto de 3) | aborta y no toca p4 |
| `data-on-p3-with-p4` | DATA valida en p3 con p4 presente | monta p3 y jamas toca p4 |
| `estaticos` | el archivo del PR | sin `fat32`, sin mkfs vfat, `mkfs.ext4 -F -m 0 -L DATA` exacto, fstab ext4 intacto, sintaxis con bash POSIX |

Ademas, en cada caso con particionado posible se comparan los **hashes SHA256 de
las regiones** `p1`/`p2` (y `p3`/`p4` cuando existen) de la copia antes y
despues, y se inspeccionan **stdout, stderr y exit code** por separado.

### Limitaciones (lo que este banco NO prueba)

* No es un boot real de kernel/init ni corre en la radio: los montajes y los
  loop devices son del kernel del host, la publicacion de nodos la hace el banco
  (no udev) y no hay RF ni SD fisica. La validacion en radio con SD virgen queda
  como `PENDING_HARDWARE` (pipeline de QA remoto separado).
* El userland es ARM real (Debian armhf, glibc, bash 5.2) con las mismas
  versiones upstream que el target (`parted` 3.5, util-linux 2.38.1), pero **no**
  es la rootfs Buildroot de la ROM (`X6200_defconfig`): no reemplaza la
  verificacion del rootfs generado.
* La tabla se edita en algunos casos con `parted` sobre el archivo (no via el
  script), lo que es equivalente pero no idéntico a un disco recien escrito.

## `S02update` (issue #215)

El **mismo archivo** vive en los dos puntos de instalacion: este repo
(`br2_external/board/X6200/linux/rootfs-overlay/etc/init.d/S02update`, lo que
corre una imagen recien grabada) y `x6200_gui`
(`tools/release/update-overlay/etc/init.d/S02update`, lo que instala una
actualizacion). `x6200_gui` tiene el gate de paridad
(`tools/release/check_updater_parity.sh`, mismo hash o falla) y **el banco del
contrato de actualizacion**: `tests/release/test_safe_update.sh` (contenedor
privado con qemu-user, chroot sobre una copia de una rootfs real, matriz de
paquetes buenos y malos, backup, sidecar, setuid y el primer update de una
imagen historica como `UNSUPPORTED/UNSAFE_LEGACY`).

No hace falta duplicarlo aca: el script que se prueba es byte a byte el mismo
que este repo instala en la imagen, y el gate de paridad es el que garantiza que
sigan iguales.

`rootfs-overlay/etc/fstab` y `S01create_data` **no** son parte de este cambio
(son responsabilidad del issue de DATA, #212).

