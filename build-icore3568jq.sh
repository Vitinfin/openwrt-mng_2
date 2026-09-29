#!/bin/bash
# =============================================================================
# СБОРКА OPENWRT ДЛЯ ICORE-3568JQ (RK3568J)
# =============================================================================
# Требования: Ubuntu/Debian 22.04+, 50 ГБ свободного места, 8+ ГБ RAM
# Запуск:
#   ./build-icore3568jq.sh [--clean] [--menuconfig] [--build [PKG]] [--package NAME] [--vscode]
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# КОНФИГУРАЦИЯ
# =============================================================================
OPENWRT_DIR="${OPENWRT_DIR:-$HOME/openwrt}"
CONFIG_BACKUP="${CONFIG_BACKUP:-$HOME/MNG_2/openwrt-config/icore-3568jq.config}"
OPENWRT_BRANCH="${OPENWRT_BRANCH:-openwrt-25.12}"
TARGET_BOARD="icore-3568jq"
TARGET_SOC_DIR="rockchip"
TARGET_PROFILE_DIR="rockchip/armv8"
TARGET_BIN_DIR="bin/targets/${TARGET_SOC_DIR}/armv8"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
ENABLE_LOCALMIRRORS="${ENABLE_LOCALMIRRORS:-0}"
BUILD_LOG="${BUILD_LOG:-$OPENWRT_DIR/build.log}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
MIN_RAM_GB="${MIN_RAM_GB:-4}"

# Можно переопределить через переменную окружения OPENWRT_LOCALMIRRORS.
# Формат: одна ссылка на строку.
OPENWRT_LOCALMIRRORS="${OPENWRT_LOCALMIRRORS:-}"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

on_error() {
    local exit_code=$?
    error "Скрипт завершился с ошибкой (код ${exit_code}) на строке ${BASH_LINENO[0]}"
}
trap on_error ERR

usage() {
    cat <<EOF
Использование: $0 [ОПЦИЯ]

ОПЦИИ:
  --clean            Полная очистка tree (make dirclean)
  --menuconfig       Подготовка tree + feeds + menuconfig
  --build [PKG]      Сборка всего образа или конкретного пакета
  --package NAME     Сборка только указанного пакета
  --vscode           Создать .vscode/tasks.json и c_cpp_properties.json
  --fix-mirrors      Создать scripts/localmirrors из OPENWRT_LOCALMIRRORS
  --help             Показать эту справку

ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
  OPENWRT_DIR           Путь к дереву OpenWrt (по умолчанию: ~/openwrt)
  CONFIG_BACKUP         Путь к .config бэкапу
  OPENWRT_BRANCH        Тег/ветка OpenWrt (по умолчанию: v24.12.0)
  BUILD_JOBS            Количество потоков для make (по умолчанию: nproc)
  ENABLE_LOCALMIRRORS   1 — создать scripts/localmirrors
  OPENWRT_LOCALMIRRORS  Список зеркал, по одному URL на строку
EOF
}

# =============================================================================
# 1. ПРОВЕРКА ЗАВИСИМОСТЕЙ
# =============================================================================
check_dependencies() {
    log "Проверка зависимостей..."

    local base_pkgs=(
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
        gettext git libncurses-dev libssl-dev libelf-dev libgmp3-dev libmpc-dev
        libzstd-dev make patch perl python3 python3-dev python3-setuptools
        rsync swig unzip zlib1g-dev file wget curl bc cpio fastjar help2man
        quilt subversion time xsltproc zstd
        device-tree-compiler python3-pyelftools
    )

    # Пакеты, которые полезны, но не критичны на всех версиях Ubuntu/Debian
    local optional_pkgs=(
        default-jre-headless ecj
    )

    local missing=()
    for pkg in "${base_pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    done

    local optional_missing=()
    for pkg in "${optional_pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            optional_missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        warn "Отсутствуют обязательные пакеты: ${missing[*]}"
        read -r -p "Установить их сейчас? [y/N]: " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            sudo apt update
            sudo apt install -y "${missing[@]}"
        else
            error "Установите обязательные зависимости вручную и повторите запуск"
        fi
    fi

    if (( ${#optional_missing[@]} > 0 )); then
        warn "Не найдены опциональные пакеты: ${optional_missing[*]}"
        warn "Сборка обычно продолжится и без них, если они не нужны вашим пакетам"
    fi

    success "Зависимости проверены"
}

# =============================================================================
# 2. КЛОНИРОВАНИЕ И ПОДГОТОВКА ИСХОДНИКОВ
# =============================================================================
setup_openwrt() {
    log "Подготовка OpenWrt в: $OPENWRT_DIR"

    if [[ ! -d "$OPENWRT_DIR/.git" ]]; then
        log "Клонирование репозитория..."
        mkdir -p "$(dirname "$OPENWRT_DIR")"
        git clone https://git.openwrt.org/openwrt/openwrt.git "$OPENWRT_DIR"
    fi

    cd "$OPENWRT_DIR"

    log "Обновление репозитория и переключение на $OPENWRT_BRANCH..."
    git fetch --all --tags --prune

    log "Переключение на ветку: $OPENWRT_BRANCH"

    if ! git checkout "$OPENWRT_BRANCH"; then
        warn "Не удалось переключиться на $OPENWRT_BRANCH"
        warn "Fallback → main"
        git checkout main || error "Не удалось переключиться даже на main"
    fi

    log "Обновление feeds..."
    ./scripts/feeds update -a
    ./scripts/feeds install -a

    success "OpenWrt готов"
}

ensure_openwrt_tree() {
    if [[ ! -d "$OPENWRT_DIR" ]]; then
        setup_openwrt
        return
    fi

    cd "$OPENWRT_DIR"
}

# =============================================================================
# 3. КАСТОМНЫЙ DTS И ОПИСАНИЕ УСТРОЙСТВА
# =============================================================================
create_custom_dts() {
    log "Подготовка файлов платы $TARGET_BOARD..."

    local dts_dir="target/linux/${TARGET_SOC_DIR}/files/arch/arm64/boot/dts/rockchip"
    local dts_path="${dts_dir}/${TARGET_BOARD}.dts"
    local mk_path="target/linux/${TARGET_SOC_DIR}/image/armv8.mk"

    mkdir -p "$dts_dir"

    if [[ ! -f "$dts_path" ]]; then
        cat > "$dts_path" <<'DTSEOF'
// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
/dts-v1/;

#include "rk3568.dtsi"

/ {
    model = "iCore-3568JQ";
    compatible = "icore,3568jq", "rockchip,rk3568";

    aliases {
        serial0 = &uart2;
        ethernet0 = &gmac1;
    };

    chosen {
        stdout-path = "serial0:1500000n8";
    };

    memory@0 {
        device_type = "memory";
        reg = <0x0 0x0 0x0 0x80000000>; /* 2 GiB */
    };
};

&uart2 {
    status = "okay";
};

&gmac1 {
    status = "okay";
};

/*
 * ВАЖНО:
 * 1) Это шаблон, а не окончательно проверенный DTS.
 * 2) Пины, регуляторы, CAN, PHY и reset-gpio нужно сверить с платой.
 * 3) Для реальной сборки лучше перенести сюда точную развязку из vendor DTS.
 */
DTSEOF
        success "Создан шаблон DTS: $dts_path"
    else
        warn "DTS уже существует: $dts_path"
    fi

    if ! grep -qE "define[[:space:]]+Device/${TARGET_BOARD}\b" "$mk_path"; then
        log "Добавление профиля платы в $mk_path..."
        # ВАЖНО: одинарные кавычки вокруг 'MKEOF' запрещают bash подстановку переменных
        cat >> "$mk_path" <<'MKEOF'


define Device/${TARGET_BOARD}
  $$(Device/rk3568)
  DEVICE_VENDOR := iCore
  DEVICE_MODEL := 3568JQ
  DEVICE_DTS := ${TARGET_BOARD}
  DEVICE_PACKAGES := kmod-can kmod-can-raw can-utils kmod-usb-net kmod-usb-net-rndis kmod-gpio-button-hotplug
endef
TARGET_DEVICES += ${TARGET_BOARD}
MKEOF
        success "Устройство добавлено в сборку"
    else
        warn "Профиль Device/${TARGET_BOARD} уже есть в armv8.mk"
    fi
}

# =============================================================================
# 4. НАСТРОЙКА КОНФИГУРАЦИИ
# =============================================================================
setup_config() {
    log "Настройка .config..."

    # 1. Восстановление или создание конфига
    if [[ -f "$CONFIG_BACKUP" ]]; then
        log "Восстановление конфигурации из: $CONFIG_BACKUP"
        cp "$CONFIG_BACKUP" .config
        
        # Если бэкап был сделан через diffconfig.sh, make defconfig развернет его.
        # Если это полный .config, make defconfig просто валидирует его.
        make defconfig > /dev/null 2>&1
    else
        warn "Бэкап конфигурации не найден: $CONFIG_BACKUP"
        
        # Защита от зависания в неинтерактивном режиме (cron, ssh без tty, CI)
        if [ -t 0 ]; then
            log "Запуск make menuconfig..."
            make menuconfig
        else
            error "Невозможно запустить menuconfig в неинтерактивном режиме!"
            error "Поместите готовый .config по пути: $CONFIG_BACKUP"
            exit 1
        fi
        
        mkdir -p "$(dirname "$CONFIG_BACKUP")"
        
        # СОХРАНЯЕМ ПОЛНЫЙ КОНФИГ для гарантии стабильности будущих сборок
        cp .config "$CONFIG_BACKUP"
        # Если вам принципиально нужен именно diff, раскомментируйте строку ниже:
        # ./scripts/diffconfig.sh > "$CONFIG_BACKUP"
        
        success "Сохранён полный конфиг: $CONFIG_BACKUP"
    fi

    # 2. Строгая проверка Target и Subtarget
    if ! grep -q '^CONFIG_TARGET_rockchip=y' .config || ! grep -q '^CONFIG_TARGET_rockchip_armv8=y' .config; then
        error "Не выбран правильный Target или Subtarget!"
        error "Ожидается: Target System -> Rockchip, Subtarget -> ARMv8 boards with 64-bit CPU"
        exit 1
    fi

    # 3. Строгая проверка КОНКРЕТНОГО профиля устройства
    # ВНИМАНИЕ: Замените на точное имя профиля из menuconfig!
    # (Оно может быть firefly_itx-3568q, icore_3568jq или другим, в зависимости от вашего патча)
    EXPECTED_DEVICE="icore_3568jq" 
    
    if ! grep -q "^CONFIG_TARGET_rockchip_armv8_DEVICE_${EXPECTED_DEVICE}=y" .config; then
        error "Не выбран профиль устройства ${EXPECTED_DEVICE}!"
        
        # Показываем, что именно выбрано сейчас, чтобы было легче дебажить
        CURRENT_DEVICE=$(grep '^CONFIG_TARGET_rockchip_armv8_DEVICE_' .config | cut -d'=' -f1 | sed 's/CONFIG_TARGET_rockchip_armv8_DEVICE_//')
        if [[ -n "$CURRENT_DEVICE" ]]; then
            error "Сейчас в .config выбрано: $CURRENT_DEVICE (это не ваша плата!)"
        else
            error "Профиль устройства вообще не выбран."
        fi
        
        error "Проверьте в menuconfig: Target Profile -> ${EXPECTED_DEVICE}"
        exit 1
    fi

    success "Конфигурация для ${EXPECTED_DEVICE} проверена и корректна."
}

# =============================================================================
# 5. ЗЕРКАЛА ДЛЯ СКАЧИВАНИЯ
# =============================================================================
fix_mirrors() {
    log "Настройка scripts/localmirrors..."

    if [[ -z "$OPENWRT_LOCALMIRRORS" ]]; then
        warn "OPENWRT_LOCALMIRRORS не задан — файл не создаю"
        return
    fi

    mkdir -p scripts
    printf '%s\n' "$OPENWRT_LOCALMIRRORS" > scripts/localmirrors
    success "Создан scripts/localmirrors"
}

# =============================================================================
# 6. СБОРКА
# =============================================================================
do_build() {
    local package="${1:-}"

    log "Загрузка исходников..."
    make download -j"$BUILD_JOBS" || warn "Часть файлов не скачалась. Повторите make download при необходимости"

    if [[ -d dl ]]; then
        local broken
        broken=$(find dl -type f -size -1024c 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${broken:-0}" -gt 0 ]]; then
            warn "Найдено битых/пустых файлов в dl/: $broken"
            find dl -type f -size -1024c -delete
            make download -j"$BUILD_JOBS"
        fi
    fi

    if [[ -n "$package" ]]; then
        validate_package_name "$package"
        log "Сборка пакета: $package"
        make "package/${package}/compile" V=s
    else
        log "Полная сборка прошивки..."
        make -j"$BUILD_JOBS" V=s 2>&1 | tee build.log
    fi

    success "Сборка завершена"
}

validate_package_name() {
    local package="$1"
    if [[ ! "$package" =~ ^[A-Za-z0-9._/+:-]+$ ]]; then
        error "Недопустимое имя пакета: $package"
    fi
}

# =============================================================================
# 7. РЕЗУЛЬТАТЫ
# =============================================================================
show_results() {
    echo
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  РЕЗУЛЬТАТЫ СБОРКИ ДЛЯ $TARGET_BOARD${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"

    local bin_dir="$TARGET_BIN_DIR"
    if [[ -d "$bin_dir" ]]; then
        echo "📁 Образы находятся в: $OPENWRT_DIR/$bin_dir"
        echo
        find "$bin_dir" -maxdepth 1 \( -name '*.bin' -o -name '*.img.gz' -o -name '*.manifest' -o -name '*.itb' \) -exec ls -lh {} + 2>/dev/null || true
        echo
        echo "📦 Пакеты: $OPENWRT_DIR/bin/packages/"
    else
        warn "Каталог с результатами не найден: $bin_dir"
    fi
    echo
}

# =============================================================================
# 8. VS CODE
# =============================================================================
setup_vscode() {
    log "Создание конфигураций VS Code..."

    mkdir -p .vscode

    cat > .vscode/tasks.json <<'VSCTEOF'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "openwrt: build icore-3568jq",
      "type": "shell",
      "command": "bash",
      "args": ["-lc", "make -j${BUILD_JOBS:-$(nproc)} V=s"],
      "options": { "cwd": "${workspaceFolder}" },
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": []
    },
    {
      "label": "openwrt: menuconfig",
      "type": "shell",
      "command": "bash",
      "args": ["-lc", "TERM=xterm-256color make menuconfig"],
      "options": { "cwd": "${workspaceFolder}" },
      "presentation": { "reveal": "always", "panel": "dedicated" },
      "group": "build"
    },
    {
      "label": "openwrt: download",
      "type": "shell",
      "command": "bash",
      "args": ["-lc", "make download -j${BUILD_JOBS:-8}"],
      "options": { "cwd": "${workspaceFolder}" },
      "group": "build"
    },
    {
      "label": "openwrt: dirclean",
      "type": "shell",
      "command": "bash",
      "args": ["-lc", "make dirclean"],
      "options": { "cwd": "${workspaceFolder}" },
      "group": "build"
    }
  ]
}
VSCTEOF

    cat > .vscode/c_cpp_properties.json <<'VSCCPEOF'
{
  "version": 4,
  "configurations": [
    {
      "name": "OpenWrt",
      "compilerPath": "/usr/bin/gcc",
      "cStandard": "c11",
      "cppStandard": "c++17",
      "intelliSenseMode": "linux-gcc-x64",
      "includePath": [
        "${workspaceFolder}/**"
      ]
    }
  ]
}
VSCCPEOF

    success "VS Code конфигурации созданы"
}

# =============================================================================
# 9. УСТРАНЕНИЕ ПРОБЛЕМ
# =============================================================================
troubleshoot() {
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ЧАСТЫЕ ПРОБЛЕМЫ И РЕШЕНИЯ${NC}"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo
    echo "🔴 Зависает на host-compile:"
    echo "   → make package/<name>/host-compile V=sc"
    echo
    echo "🔴 Не скачиваются файлы:"
    echo "   → rm -rf dl/ && make download"
    echo "   → проверьте scripts/localmirrors"
    echo
    echo "🔴 Ошибки конфигурации:"
    echo "   → make defconfig"
    echo "   → make menuconfig"
    echo
    echo "🔴 DTS не применяется:"
    echo "   → проверьте DEVICE_DTS в armv8.mk (без .dts)"
    echo "   → make target/linux/compile V=s"
    echo
    echo "🔴 Мало места:"
    echo "   → make dirclean"
    echo "   → перенесите tree на SSD"
    echo
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local action="${1:-}"
    local arg2="${2:-}"

    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  OpenWrt Builder for iCore-3568JQ      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo

    case "$action" in
        --help|"")
            usage
            echo
            troubleshoot
            ;;
        --clean)
            ensure_openwrt_tree
            log "Полная очистка..."
            make dirclean
            success "Очистка завершена"
            ;;
        --menuconfig)
            check_dependencies
            setup_openwrt
            create_custom_dts
            setup_config
            ;;
        --build)
            check_dependencies
            setup_openwrt
            create_custom_dts
            setup_config
            if [[ "$arg2" == --* ]]; then
                arg2=""
            fi
            do_build "$arg2"
            show_results
            ;;
        --package)
            if [[ -z "$arg2" || "$arg2" == --* ]]; then
                error "Для --package нужно указать имя пакета: --package NAME"
            fi
            check_dependencies
            setup_openwrt
            create_custom_dts
            setup_config
            do_build "$arg2"
            ;;
        --vscode)
            ensure_openwrt_tree
            setup_vscode
            ;;
        --fix-mirrors)
            ensure_openwrt_tree
            fix_mirrors
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"

