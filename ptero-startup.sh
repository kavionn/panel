#!/usr/bin/env bash

set -u

cd /home/container
export PATH="/home/container/.local/bin:${PATH}"

is_enabled() {
  case "${1:-0}" in
    1|true|TRUE|on|ON|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -d .git ]] && is_enabled "${AUTO_UPDATE:-0}"; then
  git pull || echo "Git auto-update failed; using the current project files."
fi

if [[ -n "${NODE_PACKAGES:-}" ]]; then
  read -r -a node_packages <<<"${NODE_PACKAGES}"
  /usr/local/bin/npm install "${node_packages[@]}"
fi

if [[ -n "${UNNODE_PACKAGES:-}" ]]; then
  read -r -a unnode_packages <<<"${UNNODE_PACKAGES}"
  /usr/local/bin/npm uninstall "${unnode_packages[@]}"
fi

if [[ -f /home/container/package.json ]]; then
  /usr/local/bin/npm install
fi

ensure_ytdlp() {
  local tools_dir="/home/container/.local/bin"
  local ytdlp_bin="${tools_dir}/yt-dlp"
  local ytdlp_asset
  local ytdlp_tmp

  if [[ -x "$ytdlp_bin" ]]; then
    return 0
  fi

  case "$(uname -m)" in
    x86_64|amd64) ytdlp_asset="yt-dlp_linux" ;;
    aarch64|arm64) ytdlp_asset="yt-dlp_linux_aarch64" ;;
    *)
      echo "Unsupported yt-dlp architecture: $(uname -m)"
      return 1
      ;;
  esac

  echo "Downloading yt-dlp..."
  mkdir -p "$tools_dir" || return 1
  ytdlp_tmp="$(mktemp "${ytdlp_bin}.download.XXXXXX")" || return 1

  if curl -fSL --connect-timeout 15 --max-time 180 --retry 2 \
    "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/${ytdlp_asset}" \
    -o "$ytdlp_tmp" \
    && chmod 755 "$ytdlp_tmp" \
    && "$ytdlp_tmp" --version \
    && mv "$ytdlp_tmp" "$ytdlp_bin"; then
    echo "yt-dlp installed successfully."
  else
    rm -f "$ytdlp_tmp"
    echo "yt-dlp download failed; audio downloads may not work."
    return 1
  fi
}

ensure_ytdlp || true

start_cloudflare_tunnel() {
  local cloudflare_dir="/home/container/.cloudflare"
  local cloudflared_bin="/home/container/.local/bin/cloudflared"
  local cloudflared_arch
  local cloudflared_tmp

  mkdir -p "$cloudflare_dir" || return 1
  touch "$cloudflare_dir/tunnel.log" || return 1
  chmod 700 "$cloudflare_dir"
  chmod 600 "$cloudflare_dir/tunnel.log"

  if [[ -z "${TUNNEL_TOKEN:-}" ]]; then
    echo "Cloudflare Tunnel is enabled, but TUNNEL_TOKEN is empty." | tee -a "$cloudflare_dir/tunnel.log"
    return 1
  fi

  if [[ ! -x "$cloudflared_bin" ]]; then
    case "$(uname -m)" in
      x86_64|amd64) cloudflared_arch="amd64" ;;
      aarch64|arm64) cloudflared_arch="arm64" ;;
      *)
        echo "Unsupported cloudflared architecture: $(uname -m)" | tee -a "$cloudflare_dir/tunnel.log"
        return 1
        ;;
    esac

    echo "Downloading cloudflared..." | tee -a "$cloudflare_dir/tunnel.log"
    mkdir -p "/home/container/.local/bin" || return 1
    cloudflared_tmp="$(mktemp "${cloudflared_bin}.download.XXXXXX")" || return 1

    if curl -fSL --connect-timeout 15 --max-time 180 --retry 2 \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cloudflared_arch}" \
      -o "$cloudflared_tmp" >>"$cloudflare_dir/tunnel.log" 2>&1 \
      && chmod 755 "$cloudflared_tmp" \
      && "$cloudflared_tmp" --version >>"$cloudflare_dir/tunnel.log" 2>&1 \
      && mv "$cloudflared_tmp" "$cloudflared_bin"; then
      :
    else
      rm -f "$cloudflared_tmp"
      echo "cloudflared download failed. Check .cloudflare/tunnel.log." | tee -a "$cloudflare_dir/tunnel.log"
      return 1
    fi
  fi

  echo "Starting Cloudflare Tunnel connector..." >>"$cloudflare_dir/tunnel.log"
  (
    "$cloudflared_bin" tunnel --no-autoupdate --loglevel info run >>"$cloudflare_dir/tunnel.log" 2>&1
    cloudflared_status=$?
    echo "Cloudflare Tunnel process exited (code ${cloudflared_status}). Check .cloudflare/tunnel.log." \
      | tee -a "$cloudflare_dir/tunnel.log"
  ) &

  echo "Cloudflare Tunnel launched; check .cloudflare/tunnel.log for connection status."
}

if is_enabled "${CLOUDFLARE_TUNNEL_ENABLED:-0}"; then
  start_cloudflare_tunnel || echo "Cloudflare Tunnel setup failed; application startup will continue."
else
  echo "Cloudflare Tunnel is disabled."
fi

if [[ -z "${STARTUP_COMMAND:-}" ]]; then
  echo "STARTUP_COMMAND is empty; cannot start the Node.js application."
  exit 1
fi

echo "Starting Node.js application..."
exec /bin/bash -c "$STARTUP_COMMAND"
