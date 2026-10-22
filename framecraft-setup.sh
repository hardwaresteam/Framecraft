#!/usr/bin/env bash

set -euo pipefail

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

APP_DIR="$HOME/Applications"
APPIMAGE="$APP_DIR/PrismLauncher.AppImage"
DESKTOP_DIR="$DATA_HOME/applications"
PRISM_DATA="$DATA_HOME/PrismLauncher"
FLATPAK_PRISM_DATA="$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher"
WORK_DIR="$CACHE_HOME/framecraft"

PRISM_RELEASE_API="https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest"

mc_version="26.3"
instance_name="FrameCraft"
existing_instance=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                [ $# -ge 2 ] || die "--version needs a value"
                mc_version="$2"
                shift 2
                ;;
            --existing)
                [ $# -ge 2 ] || die "--existing needs an instance name"
                existing_instance="$2"
                instance_name="$2"
                shift 2
                ;;
            *)
                die "unknown option '$1'"
                ;;
        esac
    done
}

check_platform() {
    if [ "$(uname -m)" != "aarch64" ]; then
        die "unsupported platform: aarch64 required"
    fi
    command -v curl >/dev/null || die "curl is not installed"
    command -v python3 >/dev/null || die "python3 is not installed"
}

install_prism() {
    if [ -x "$APPIMAGE" ]; then
        echo "Prism Launcher found."
        return
    fi
    if [ -x "$HOME/PrismLauncher.AppImage" ]; then
        APPIMAGE="$HOME/PrismLauncher.AppImage"
        echo "Prism Launcher found."
        return
    fi

    echo "Downloading Prism Launcher..."
    local url
    url="$(curl -fsSL "$PRISM_RELEASE_API" | python3 -c '
import json, sys
assets = json.load(sys.stdin)["assets"]
print(next(a["browser_download_url"] for a in assets
           if a["name"].endswith("aarch64.AppImage")))
')" || die "Prism Launcher download failed"

    mkdir -p "$APP_DIR"
    curl -fL --progress-bar -o "$APPIMAGE.part" "$url"
    chmod +x "$APPIMAGE.part"
    mv "$APPIMAGE.part" "$APPIMAGE"
}

migrate_flatpak_data() {
    if [ ! -d "$PRISM_DATA" ] && [ -d "$FLATPAK_PRISM_DATA" ]; then
        echo "Importing existing Prism data..."
        mkdir -p "$(dirname "$PRISM_DATA")"
        cp -r "$FLATPAK_PRISM_DATA" "$PRISM_DATA"
    fi
}

set_default_memory() {
    local cfg="$PRISM_DATA/prismlauncher.cfg"
    if pgrep -xi "prismlauncher" >/dev/null 2>&1; then
        echo "Prism Launcher is running; memory setting skipped."
        return
    fi
    mkdir -p "$PRISM_DATA"
    if [ -f "$cfg" ] && grep -q '^MaxMemAlloc=' "$cfg"; then
        sed -i 's/^MaxMemAlloc=.*/MaxMemAlloc=6144/' "$cfg"
    else
        echo "MaxMemAlloc=6144" >> "$cfg"
    fi
}

build_modpack() {
    local pack="$1"
    echo "Building instance (Minecraft $mc_version)..."
    python3 - "$mc_version" "$instance_name" "$pack" <<'PY'
import json
import sys
import urllib.parse
import urllib.request
import zipfile

mc_version, pack_name, out_path = sys.argv[1:4]
HEADERS = {"User-Agent": "framecraft-setup/1.0"}

GAME_OPTIONS = "\n".join([
    "version:5023",
    "renderDistance:8",
    "simulationDistance:6",
    "enableVsync:false",
    "maxFps:260",
    'renderClouds:"false"',
    "particles:2",
    "entityShadows:false",
    "",
])
VIVECRAFT_OPTIONS = {
    "vrFreeMoveMode": "HMD",
    "displayMirrorMode": "OFF",
}
SODIUM_OPTIONS = {
    "quality": {"pixel_filtering_mode": "NEAREST"},
    "performance": {
        "chunk_build_defer_mode": "ALWAYS",
        "animate_only_visible_textures": True,
        "use_entity_culling": True,
        "use_fog_occlusion": True,
        "use_block_face_culling": True,
    },
}

def get_json(url):
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)

def fabric_loader_version():
    loaders = get_json(f"https://meta.fabricmc.net/v2/versions/loader/{mc_version}")
    if not loaders:
        sys.exit(f"error: Fabric does not support Minecraft {mc_version}")
    stable = [entry for entry in loaders if entry["loader"].get("stable")]
    return (stable or loaders)[0]["loader"]["version"]

def resolve_mods(required, optional=()):
    entries, seen = [], set()

    def add(project, is_optional=False):
        if project in seen:
            return
        seen.add(project)
        query = urllib.parse.urlencode({
            "loaders": json.dumps(["fabric"]),
            "game_versions": json.dumps([mc_version]),
        })
        versions = get_json(f"https://api.modrinth.com/v2/project/{project}/version?{query}")
        if not versions:
            if is_optional:
                print(f"  {project}: skipped")
                return
            sys.exit(f"error: no Fabric build of '{project}' for Minecraft {mc_version}")
        version = versions[0]
        seen.add(version["project_id"])
        file = next((f for f in version["files"] if f.get("primary")), version["files"][0])
        entries.append({
            "path": f"mods/{file['filename']}",
            "hashes": {"sha1": file["hashes"]["sha1"], "sha512": file["hashes"]["sha512"]},
            "env": {"client": "required", "server": "unsupported"},
            "downloads": [file["url"]],
            "fileSize": file["size"],
        })
        print(f"  {file['filename']}")
        for dependency in version.get("dependencies", []):
            if dependency.get("dependency_type") == "required" and dependency.get("project_id"):
                add(dependency["project_id"])

    for project in required:
        add(project)
    for project in optional:
        add(project, is_optional=True)
    return entries

loader = fabric_loader_version()
index = {
    "formatVersion": 1,
    "game": "minecraft",
    "versionId": "1.1",
    "name": pack_name,
    "summary": "FrameCraft",
    "files": resolve_mods(required=["vivecraft"], optional=["sodium"]),
    "dependencies": {"minecraft": mc_version, "fabric-loader": loader},
}
with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as pack:
    pack.writestr("modrinth.index.json", json.dumps(index, indent=2))
    pack.writestr("overrides/options.txt", GAME_OPTIONS)
    pack.writestr("overrides/config/vivecraft-client-config.json",
                  json.dumps(VIVECRAFT_OPTIONS, indent=2))
    pack.writestr("overrides/config/sodium-options.json",
                  json.dumps(SODIUM_OPTIONS, indent=2))
print(f"  Fabric loader {loader}")
PY
}

write_desktop_entries() {
    echo "Creating shortcuts..."
    mkdir -p "$DESKTOP_DIR"

    cat > "$DESKTOP_DIR/framecraft.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=FrameCraft
Exec="$APPIMAGE" --launch "$instance_name"
Icon=applications-games
Categories=Game;
EOF

    cat > "$DESKTOP_DIR/prismlauncher-appimage.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Prism Launcher (AppImage)
Exec="$APPIMAGE"
Icon=applications-games
Categories=Game;
EOF

    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
}

add_to_steam() {
    echo "Adding to Steam..."
    if command -v steamos-add-to-steam >/dev/null 2>&1 \
        && steamos-add-to-steam "$DESKTOP_DIR/framecraft.desktop" >/dev/null 2>&1; then
        return 0
    fi
    echo "  Not added to Steam automatically."
}

main() {
    parse_args "$@"
    check_platform
    install_prism
    migrate_flatpak_data

    local pack=""
    if [ -z "$existing_instance" ]; then
        set_default_memory
        mkdir -p "$WORK_DIR"
        pack="$WORK_DIR/framecraft-$mc_version.mrpack"
        build_modpack "$pack"
    fi

    write_desktop_entries
    add_to_steam

    echo
    if [ -n "$pack" ]; then
        nohup "$APPIMAGE" --import "$pack" >/dev/null 2>&1 &
        echo "Done. Confirm the import in Prism Launcher."
    else
        echo "Done."
    fi
}

main "$@"
