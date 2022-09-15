#!/usr/bin/env bash
set -euo pipefail

# Prerequisites:
#   * curl
#   * jq
#   * sha1sum (optional, skips hash verification if not installed)

# You can also run this script as:
# bash <(curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/printfn/mc/main/download.sh) --help

usage="Usage: download.sh [flags] <version>

Downloads a specified Minecraft server.jar file

<version> can be a version number like '1.18.2', or it can be 'latest',
    'latest-snapshot', 'list', 'list-latest' or 'list-latest-snapshot'

Forge installers can also be downloaded by specifying 'forge:1.18.2',
    'forge:1.18.2-40.1.80' or 'forge:list'

Flags:
    --curl-flag <flag>  passes the specified flag through to \`curl\`
-h  --help              show this help screen
-q  --quiet             suppress output
-v  --verbose           show more detailed output"

quiet=false
verbose=false
foundcmd=false
curlflags=""

while [[ "$#" != 0 ]]; do
    arg="$1"
    if [[ "$arg" == "-q" || "$arg" == "--quiet" ]]; then
        quiet=true
    elif [[ "$arg" == "-v" || "$arg" == "--verbose" ]]; then
        verbose=true
    elif [[ "$arg" == "--curl-flag" ]]; then
        shift
        if [[ "$#" == 0 ]]; then
            echo "error: expected a curl flag" >&2
            exit 1
        fi
        curlflags="$curlflags $1"
    elif [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        echo "$usage"
        exit
    elif [[ "$arg" =~ ^- ]]; then
        echo "error: unknown option '$arg'" >&2
        exit 1
    elif [[ "$foundcmd" == false ]]; then
        command="$arg"
        foundcmd=true
    else
        echo "error: too many arguments" >&2
        exit 1
    fi
    shift
done

if [[ "$foundcmd" == false ]]; then
    echo "$usage" >&2
    exit 1
fi

mycurl() {
    # shellcheck disable=SC2086
    curl -f $curlflags "$@"
}

verify_hash() {
    local filename="$1"
    local sha1="$2"

    if command -v sha1sum &>/dev/null; then
        if sha1sum --check --strict --status <(echo "$sha1 $filename"); then
            if [[ "$verbose" == true ]]; then
                echo "Successfully verified checksum with \`sha1sum\`"
            fi
        else
            echo "error: checksum mismatch" >&2
            exit 1
        fi
    elif command -v shasum &>/dev/null; then
        # two spaces are necessary, otherwise `shasum` returns an error`
        if shasum --algorithm 1 --check --strict --status <(echo "$sha1  $filename"); then
            if [[ "$verbose" == true ]]; then
                echo "Successfully verified checksum with \`shasum\`"
            fi
        else
            echo "error: checksum mismatch" >&2
            exit 1
        fi
    else
        # skip verification
        echo "warning: neither \`sha1sum\` or \`shasum\` is installed: skipping hash verification" >&2
        exit
    fi
}

download_mc() {
    local mc_command="$1"
    if [[ "$verbose" == true ]]; then
        echo "Downloading version manifest from https://launchermeta.mojang.com/mc/game/version_manifest.json..."
    fi
    data=$(mycurl -sS https://launchermeta.mojang.com/mc/game/version_manifest.json)

    if [[ "$mc_command" == "latest" ]]; then
        version=$(echo "$data" | jq -r .latest.release)
    elif [[ "$mc_command" == "list-latest" ]]; then
        echo "$data" | jq -r ".latest.release"
        exit
    elif [[ "$mc_command" == "latest-snapshot" ]]; then
        version=$(echo "$data" | jq -r .latest.snapshot)
    elif [[ "$mc_command" == "list-latest-snapshot" ]]; then
        echo "$data" | jq -r ".latest.snapshot"
        exit
    elif [[ "$mc_command" == "list" ]]; then
        echo "$data" | jq -r ".versions[].id"
        exit
    else
        version="$mc_command"
    fi

    if [[ "$verbose" == true ]]; then
        echo "Found version $version"
    elif [[ "$quiet" != true ]]; then
        echo "Downloading version $version..."
    fi

    url=$(echo "$data" | jq -r ".versions[] | select(.id == \"$version\") | .url")
    if [[ -z "$url" ]]; then
        echo "error: unknown version '$version'" >&2
        exit 1
    fi

    if [[ "$verbose" == true ]]; then
        echo "Downloading version info from $url..."
    fi

    data=$(mycurl -sS "$url" | jq .downloads.server)
    url=$(echo "$data" | jq -r .url)

    if [[ "$verbose" == true ]]; then
        echo "Downloading server.jar from $url..."
    fi

    sha1=$(echo "$data" | jq -r .sha1)

    curlsilent=""
    if [[ "$quiet" == true ]]; then
        curlsilent="--silent"
    fi

    mycurl $curlsilent -# -o server.jar "$url"

    verify_hash server.jar "$sha1"
}

download_forge_version() {
    # downloads a specific forge version, e.g. '1.18.2-40.1.80'
    local longversion="$1"

    meta=$(mycurl -sS "https://files.minecraftforge.net/net/minecraftforge/forge/$longversion/meta.json")
    installer_md5=$(echo "$meta" | jq -r ".classifiers.installer.jar")
    if [[ "$verbose" == true ]]; then
        echo "MD5 checksum is $installer_md5"
    fi

    local filename="forge-$longversion-installer.jar"
    mycurl -#O "https://maven.minecraftforge.net/net/minecraftforge/forge/$longversion/$filename"
}

download_forge() {
    local forge_version="$1"

    local url="https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json"
    if [[ "$verbose" == true ]]; then
        echo "Downloading forge promotions from $url..."
    fi
    local promotions
    promotions=$(mycurl -sS "$url")

    if [[ "$forge_version" == "list" ]]; then
        mycurl -sS "https://files.minecraftforge.net/net/minecraftforge/forge/maven-metadata.json" | jq -r "flatten | .[]"
        echo "$promotions" | jq -r ".promos | keys[]"
        return
    fi
    
    local target_version

    target_version=$(echo "$promotions" | jq -r ".promos[\"$forge_version\"]")
    if [[ -n "$target_version" && "$target_version" != "null" ]]; then
        local mc_version
        mc_version=$(echo "$forge_version" | grep -o "[0-9.]\\+")
        if [[ "$verbose" == true ]]; then
            echo "Found matching forge release '$mc_version-$target_version'"
        fi
        download_forge_version "$mc_version-$target_version"
        return
    fi
    target_version=$(echo "$promotions" | jq -r ".promos[\"${forge_version}-latest\"]")
    if [[ -n "$target_version" && "$target_version" != "null" ]]; then
        if [[ "$verbose" == true ]]; then
            echo "Found matching forge release '$forge_version-$target_version'"
        fi
        download_forge_version "$forge_version-$target_version"
        return
    fi
    download_forge_version "$forge_version"
}

download() {
    local name="$1"
    if [[ "$name" =~ ^forge: ]]; then
        # shellcheck disable=SC2001
        download_forge "$(echo "$name" | sed "s/^forge://")"
    else
        download_mc "$name"
    fi
}

download "$command"
