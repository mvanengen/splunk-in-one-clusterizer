#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LICENSE_PATH=""
CLUSTER_CONFIG=""
FREE_MODE=false
ACTION="up"
CONFIG_ACTIVE=false

declare -a LOCAL_ROLES=()
REMOTE_HOST_CLUSTER_MASTER=""
REMOTE_HOST_INDEXER=""
REMOTE_HOST_LICENSE_MASTER=""
REMOTE_HOST_DEPLOYMENT_SERVER=""
REMOTE_HOST_SEARCH_HEAD=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start a Splunk environment using Docker Compose files found in $(basename "$SCRIPT_DIR")/.

Options:
  --license PATH          Path to Splunk license file (default: ./license.txt)
  --free                  Deploy without a license (Free License, limited ingestion)
  --cluster-config PATH   Multi-machine deployment config (default: ./cluster.yml)
  --down                  Tear down containers started by this script
  -h, --help              Show this help message

If --cluster-config is not provided, the script looks for cluster.yml in
the script directory. If found, only local roles are started. If not found,
all compose files are started (single-machine mode).

The script looks for docker-compose-*.yml files in $(basename "$SCRIPT_DIR")/ and starts
each one sequentially. Missing compose files are skipped gracefully.
A valid Splunk license is required unless --free is specified.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --license)
                LICENSE_PATH="$2"
                shift 2
                ;;
            --free)
                FREE_MODE=true
                shift
                ;;
            --cluster-config)
                CLUSTER_CONFIG="$2"
                shift 2
                ;;
            --down)
                ACTION="down"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    if [[ "$FREE_MODE" == true && -n "$LICENSE_PATH" ]]; then
        echo "Error: --free and --license cannot be used together." >&2
        exit 1
    fi
}

parse_cluster_config() {
    local config_file="$1"

    while IFS= read -r role; do
        role="$(echo "$role" | sed 's/^[[:space:]]*-[[:space:]]*//' | xargs)"
        [[ -n "$role" ]] && LOCAL_ROLES+=("$role")
    done < <(sed -n '/^local:/,/^[a-z]/p' "$config_file" | grep '^[[:space:]]*-')

    while IFS='=' read -r role hosts; do
        [[ -z "$role" ]] && continue
        case "$role" in
            cluster-master)    REMOTE_HOST_CLUSTER_MASTER="$hosts" ;;
            indexer)           REMOTE_HOST_INDEXER="$hosts" ;;
            license-master)    REMOTE_HOST_LICENSE_MASTER="$hosts" ;;
            deployment-server) REMOTE_HOST_DEPLOYMENT_SERVER="$hosts" ;;
            search-head)       REMOTE_HOST_SEARCH_HEAD="$hosts" ;;
        esac
    done < <(awk '
    /^remote:/ { found=1; next }
    found && /^[a-z]/ { exit }
    found && /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        sub(/:[[:space:]]*$/, "", line)
        current_role = line
    }
    found && current_role && /host:/ {
        val = $0
        sub(/.*host:[[:space:]]*/, "", val)
        sub(/[[:space:]]*$/, "", val)
        if (current_role in hosts) {
            hosts[current_role] = hosts[current_role] "," val
        } else {
            hosts[current_role] = val
        }
    }
    END {
        for (role in hosts) {
            print role "=" hosts[role]
        }
    }
    ' "$config_file")

    local all_roles=(search-head indexer cluster-master license-master deployment-server forwarder)
    local required_roles=(cluster-master indexer)

    for role in "${all_roles[@]}"; do
        local in_local=false
        local in_remote=false

        if [[ ${#LOCAL_ROLES[@]} -gt 0 ]]; then
            local local_str=" ${LOCAL_ROLES[*]} "
            [[ "$local_str" =~ " ${role} " ]] && in_local=true
        fi

        case "$role" in
            cluster-master)    [[ -n "$REMOTE_HOST_CLUSTER_MASTER" ]] && in_remote=true ;;
            indexer)           [[ -n "$REMOTE_HOST_INDEXER" ]] && in_remote=true ;;
            license-master)    [[ -n "$REMOTE_HOST_LICENSE_MASTER" ]] && in_remote=true ;;
            deployment-server) [[ -n "$REMOTE_HOST_DEPLOYMENT_SERVER" ]] && in_remote=true ;;
            search-head)       [[ -n "$REMOTE_HOST_SEARCH_HEAD" ]] && in_remote=true ;;
        esac

        if [[ "$in_local" == false && "$in_remote" == false ]]; then
            local is_required=false
            for rr in "${required_roles[@]}"; do
                [[ "$rr" == "$role" ]] && is_required=true && break
            done

            if [[ "$is_required" == true ]]; then
                echo "Error: role '$role' is not configured as local or remote." >&2
                echo "This role is required. Add it to local: or remote: in $(basename "$config_file")." >&2
                exit 1
            else
                echo "Warning: role '$role' is not configured as local or remote." >&2
                echo "It will not be part of the cluster." >&2
            fi
        fi
    done
}

_build_and_export() {
    local role="$1"
    local container_name="$2"
    local env_var="$3"
    local parts=()

    if [[ ${#LOCAL_ROLES[@]} -gt 0 ]]; then
        local local_str=" ${LOCAL_ROLES[*]} "
        if [[ "$local_str" =~ " ${role} " ]]; then
            parts+=("$container_name")
        fi
    fi

    local remote_val=""
    case "$role" in
        cluster-master)    remote_val="$REMOTE_HOST_CLUSTER_MASTER" ;;
        indexer)           remote_val="$REMOTE_HOST_INDEXER" ;;
        license-master)    remote_val="$REMOTE_HOST_LICENSE_MASTER" ;;
        deployment-server) remote_val="$REMOTE_HOST_DEPLOYMENT_SERVER" ;;
        search-head)       remote_val="$REMOTE_HOST_SEARCH_HEAD" ;;
    esac

    if [[ -n "$remote_val" ]]; then
        local IFS=','
        read -ra remote_parts <<< "$remote_val"
        for h in "${remote_parts[@]}"; do
            h="$(echo "$h" | xargs)"
            [[ -n "$h" ]] && parts+=("$h")
        done
    fi

    if [[ ${#parts[@]} -gt 0 ]]; then
        local IFS=','
        export "$env_var"="${parts[*]}"
    fi
}

build_peer_env() {
    _build_and_export "cluster-master" "splunk-cluster-master" "SPLUNK_CLUSTER_MASTER_URL"
    _build_and_export "indexer" "splunk-indexer" "SPLUNK_INDEXER_URL"
    _build_and_export "license-master" "splunk-license-master" "SPLUNK_LICENSE_MASTER_URL"
    _build_and_export "deployment-server" "splunk-deployment-server" "SPLUNK_DEPLOYMENT_SERVER"
    _build_and_export "search-head" "splunk-search-head" "SPLUNK_SEARCH_HEAD_URL"
}

find_license() {
    if [[ "$FREE_MODE" == true ]]; then
        echo "Running in Free mode. Splunk is limited to 500 MB/day ingestion."
        echo "No license file will be used."
        return 0
    fi

    if [[ -n "$LICENSE_PATH" ]]; then
        if [[ ! -f "$LICENSE_PATH" ]]; then
            echo "Error: license file not found at '$LICENSE_PATH'" >&2
            exit 1
        fi
    else
        if [[ -f "$SCRIPT_DIR/license.txt" ]]; then
            LICENSE_PATH="$SCRIPT_DIR/license.txt"
        elif [[ -f "./license.txt" ]]; then
            LICENSE_PATH="./license.txt"
        else
            echo "Error: no license file found." >&2
            echo "" >&2
            echo "Splunk will use either the Trial License (60-day expiry) or" >&2
            echo "the Free License (heavily limited to 500 MB/day ingestion)." >&2
            echo "" >&2
            echo "To deploy without a license, re-run with: --free" >&2
            echo "Or provide a license with: --license <path>" >&2
            exit 1
        fi
    fi

    local target="$SCRIPT_DIR/license.txt"
    if [[ "$(realpath "$LICENSE_PATH")" != "$(realpath "$target")" ]]; then
        cp "$LICENSE_PATH" "$target"
        echo "Copied license to $target"
    fi
    echo "Using license: $LICENSE_PATH"
}

find_compose_files() {
    local files=()
    for f in "$SCRIPT_DIR"/docker-compose-*.yml "$SCRIPT_DIR"/docker-compose-*.yaml; do
        [[ -f "$f" ]] || continue

        if [[ "$CONFIG_ACTIVE" == true ]]; then
            local role
            role="$(basename "$f" .yml)"
            role="${role#docker-compose-}"
            role="${role%.yaml}"

            if [[ ${#LOCAL_ROLES[@]} -gt 0 ]]; then
                local is_local=false
                for lr in "${LOCAL_ROLES[@]}"; do
                    [[ "$lr" == "$role" ]] && is_local=true && break
                done
                [[ "$is_local" == false ]] && continue
            else
                continue
            fi
        fi

        files+=("$f")
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "Warning: no docker-compose-*.yml files found in $(basename "$SCRIPT_DIR")/" >&2
        exit 1
    fi
    echo "${files[@]}"
}

bring_down() {
    echo "--- Tearing down Splunk containers ---"

    local config_file=""
    if [[ -n "$CLUSTER_CONFIG" ]]; then
        if [[ ! -f "$CLUSTER_CONFIG" ]]; then
            echo "Error: cluster config not found at '$CLUSTER_CONFIG'" >&2
            exit 1
        fi
        config_file="$CLUSTER_CONFIG"
    elif [[ -f "$SCRIPT_DIR/cluster.yml" ]]; then
        config_file="$SCRIPT_DIR/cluster.yml"
    fi

    if [[ -n "$config_file" ]]; then
        if [[ ${#LOCAL_ROLES[@]} -eq 0 ]]; then
            parse_cluster_config "$config_file"
        fi

        if [[ -z "$CLUSTER_CONFIG" ]]; then
            echo "Warning: $(basename "$config_file") found but --cluster-config was not provided." >&2
            echo "Only stopping local roles defined in the config." >&2
            echo "" >&2
        fi

        CONFIG_ACTIVE=true
        if [[ ${#LOCAL_ROLES[@]} -gt 0 ]]; then
            echo "Local roles to tear down: ${LOCAL_ROLES[*]}"
        else
            echo "No local roles configured. Nothing to tear down."
            return 0
        fi
        echo ""
    fi

    local files
    read -ra files <<< "$(find_compose_files)" || true
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "Nothing to tear down."
        return 0
    fi
    local compose_args=()
    for f in "${files[@]}"; do
        echo "Stopping: $(basename "$f")"
        compose_args+=(-f "$f")
    done
    docker compose --project-name splunk "${compose_args[@]}" down
    echo "--- All containers stopped ---"
}

wait_for_splunk() {
    local name="$1"
    local container="$2"
    local port="${3:-8089}"
    local port2="${4:-}"
    local timeout=300
    local elapsed=0
    echo "  Waiting for $name (management port $port)..."
    while ! docker exec "$container" curl -sf -o /dev/null "https://localhost:$port" --insecure 2>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $elapsed -ge $timeout ]]; then
            echo "  Warning: $name not ready after ${timeout}s, moving on." >&2
            return 0
        fi
    done
    if [[ -n "$port2" ]]; then
        echo "  Waiting for $name (port $port2)..."
        while ! docker exec "$container" curl -sf -o /dev/null "http://localhost:$port2" 2>/dev/null; do
            sleep 5
            elapsed=$((elapsed + 5))
            if [[ $elapsed -ge $timeout ]]; then
                echo "  Warning: $name port $port2 not ready after ${timeout}s, moving on." >&2
                return 0
            fi
        done
    fi
    echo "  $name is ready (${elapsed}s)."
}

bring_up() {
    if [[ "$CONFIG_ACTIVE" == true ]]; then
        build_peer_env
    fi

    echo "--- Locating compose files ---"
    local files
    read -ra files <<< "$(find_compose_files)" || true
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No compose files to start."
        return 0
    fi

    echo "Found ${#files[@]} compose file(s):"
    for f in "${files[@]}"; do
        echo "  - $(basename "$f")"
    done
    echo ""

    echo "--- Starting Splunk environment ---"
    for f in "${files[@]}"; do
        local name container
        name="$(basename "$f" .yml)"
        name="${name#docker-compose-}"
        name="${name%.yaml}"
        container="splunk-${name}"

        if [[ "$FREE_MODE" == true && "$name" == "license-master" ]]; then
            echo "Skipping: $name (Free mode — no license master needed)"
            continue
        fi

        echo "Bringing up: $name"
        docker compose --project-name splunk -f "$f" up -d
        if [[ "$name" == "indexer" ]]; then
            wait_for_splunk "$name" "$container" 8089 9997
        else
            wait_for_splunk "$name" "$container"
        fi
        echo ""
    done
    echo "--- All containers started ---"
}

main() {
    parse_args "$@"

    if [[ "$ACTION" == "down" ]]; then
        bring_down
    else
        local config_file=""
        if [[ -n "$CLUSTER_CONFIG" ]]; then
            if [[ ! -f "$CLUSTER_CONFIG" ]]; then
                echo "Error: cluster config not found at '$CLUSTER_CONFIG'" >&2
                exit 1
            fi
            config_file="$CLUSTER_CONFIG"
        elif [[ -f "$SCRIPT_DIR/cluster.yml" ]]; then
            config_file="$SCRIPT_DIR/cluster.yml"
            echo "Auto-detected cluster config: $config_file"
        fi

        if [[ -n "$config_file" ]]; then
            parse_cluster_config "$config_file"
            CONFIG_ACTIVE=true
            if [[ ${#LOCAL_ROLES[@]} -gt 0 ]]; then
                echo "Local roles: ${LOCAL_ROLES[*]}"
            else
                echo "No local roles configured. Nothing to start on this machine."
                return 0
            fi
            echo ""
        fi

        find_license
        bring_up
    fi
}

main "$@"
