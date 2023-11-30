#!/usr/bin/env bash

set -e

log() {
  local prefix=""
  if [[ -n "$host" ]]; then
    prefix="[$host] "
  fi
  echo -e "\033[1m${2:-\033[34m}$prefix$1\033[0m"
}

sshHost() { echo "${1%:*}"; }
sshPort() { [[ "$1" =~ :[0-9]+$ ]] && echo "-p${1##*:}" || echo -p22; }
nixSshHost() { echo "ssh://$(sshHost $1)"; }
nixSshPort() { echo "NIX_SSHOPTS=$(sshPort $1)"; }

nix="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

deploy() {
  host="$1"
  trap "log 'Deployment of $host failed!' \"\033[31m\"" ERR

  log "Starting deployment of $host" "\033[33m"
  log "Evaluating configuration"
  local config
  config=$($nix build --no-link --print-out-paths ".#nixosConfigurations.\"$host\".config.deploy-sh._config")
  source "$config"

  if [[ -n "$targetHostOverride" ]]; then
    targetHost="$targetHostOverride"
  fi

  if [[ -n "$buildHostOverride" ]]; then
    buildHost="$buildHostOverride"
  elif [[ $buildLocal = 1 ]]; then
    buildHost=""
  elif [[ $buildRemote = 1 ]]; then
    buildHost="$targetHost"
  fi

  if [[ -n "$buildCacheOverride" ]]; then
    buildCache="$buildCacheOverride"
  fi
  if [[ "$buildCache" = "\0" ]]; then
    buildCache=""
  fi

  if [[ -z "$buildHost" ]]; then
    log "Building locally, then deploying to $targetHost" "\033[36m"
  elif [[ "$buildHost" = "$targetHost" ]]; then
    log "Building and deploying to $targetHost" "\033[36m"
  else
    log "Building on $buildHost, then deploying to $targetHost" "\033[36m"
  fi
  if [[ -n "$buildCache" ]]; then
    if [[ -z "$buildHost" ]]; then
      log "Cache the system at $buildCache" "\033[36m"
    else
      log "Cache the system on $buildHost at $buildCache" "\033[36m"
    fi
  fi
  log "System path: $system" "\033[0m"
  log "System derivation: $systemDrv" "\033[0m"

  local nomPipe="--log-format internal-json -v |& $nom/bin/nom --json"

  if [[ -n "$buildHost" ]]; then
    log "Copying derivations to build host $buildHost"
    env $(nixSshPort "$buildHost") $nix copy --derivation --to $(nixSshHost "$buildHost") "$systemDrv^*" "$nomDrv^*"

    if [[ $fetch = 1 ]] && [[ "$targetHost" != "$buildHost" ]]; then
      if oldSystem=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") readlink /run/current-system); then
        log "Fetching old system from $targetHost"
        ssh $(sshPort "$buildHost") $(sshHost "$buildHost") env $(nixSshPort "$targetHost") $nix copy --no-check-sigs --from $(nixSshHost "$targetHost") "$oldSystem"
      else
        log "Failed to lookup current system on $targetHost" "\033[31m"
      fi
    fi

    log "Building system for $targetHost on $buildHost"
    ssh $(sshPort "$buildHost") $(sshHost "$buildHost") $nix build --no-link "$nomDrv^*"
    if [[ -n "$buildCache" ]]; then
      ssh $(sshPort "$buildHost") $(sshHost "$buildHost") "mkdir -p \"$(basename "$buildCache")\" && $nix build -o \"$buildCache\" \"$systemDrv^*\" $nomPipe"
    else
      ssh $(sshPort "$buildHost") $(sshHost "$buildHost") "$nix build --no-link \"$systemDrv^*\" $nomPipe"
    fi

    if [[ "$targetHost" != "$buildHost" ]]; then
      log "Copying system to $targetHost"
      ssh $(sshPort "$buildHost") $(sshHost "$buildHost") env $(nixSshPort "$targetHost") $nix copy --to $(nixSshHost "$targetHost") "$system"
    fi
  else
    if [[ $fetch = 1 ]]; then
      if oldSystem=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") readlink /run/current-system); then
        log "Fetching old system from $targetHost"
        env $(nixSshPort "$targetHost") $nix copy --no-check-sigs --from $(nixSshHost "$targetHost") "$oldSystem"
      else
        log "Failed to lookup current system on $targetHost" "\033[31m"
      fi
    fi

    log "Building system for $targetHost locally"
    $nix build --no-link "$nomDrv^*"
    if [[ -n "$buildCache" ]]; then
      mkdir -p $(basename "$buildCache")
      bash -c "$nix build -o \"$buildCache\" \"$systemDrv^*\" $nomPipe"
    else
      bash -c "$nix build --no-link \"$systemDrv^*\" $nomPipe"
    fi

    log "Copying system to $targetHost"
    env $(nixSshPort "$targetHost") $nix copy --to $(nixSshHost "$targetHost") "$system"
  fi

  log "Activating system on $targetHost ($action)"
  if [[ "$action" =~ ^(switch|boot|reboot)$ ]]; then
    ssh $(sshPort "$targetHost") $(sshHost "$targetHost") nix-env -p /nix/var/nix/profiles/system --set "$system"
  fi
  if [[ "$action" = "reboot" ]]; then
    ssh $(sshPort "$targetHost") $(sshHost "$targetHost") "$system/bin/switch-to-configuration" boot
    log "Rebooting $targetHost"
    ssh $(sshPort "$targetHost") $(sshHost "$targetHost") reboot
    log "Waiting for $targetHost to reboot"
    sleep 5
    while ! ssh $(sshPort "$targetHost") $(sshHost "$targetHost") true; do
      sleep 1
    done
  else
    ssh $(sshPort "$targetHost") $(sshHost "$targetHost") "$system/bin/switch-to-configuration" "$action"
  fi

  log "Deployment of $host succeeded!" "\033[32m"
}


action=switch
buildLocal=0
buildRemote=0
buildHostOverride=""
targetHostOverride=""
buildCacheOverride=""
fetch=0
deployed=0

while [[ $# -gt 0 ]]; do
  i="$1"; shift 1
  case "$i" in
    --switch|--boot|--test|--dry-activate|--reboot)
      action=${i#"--"}
      ;;
    --local)
      buildLocal=1
      buildRemote=0
      buildHostOverride=""
      ;;
    --remote)
      buildLocal=0
      buildRemote=1
      buildHostOverride=""
      ;;
    --buildHost|--build-host|--build)
      buildLocal=0
      buildRemote=0
      buildHostOverride="$1"; shift 1
      ;;
    --targetHost|--target-host|--target)
      targetHostOverride="$1"; shift 1
      ;;
    --cache)
      buildCacheOverride="$1"; shift 1
      ;;
    --no-cache)
      buildCacheOverride="\0"
      ;;
    --fetch)
      fetch=1
      ;;
    --no-fetch)
      fetch=0
      ;;
    --*)
      echo -e "\033[1m\033[31mUnknown flag: $i\033[0m"
      exit 1
      ;;
    *)
      if [[ $deployed = 1 ]]; then echo; fi
      deploy "$i"
      deployed=1
      ;;
  esac
done

if [[ $deployed = 0 ]]; then
  for host in $($nix eval --raw .#deploy-sh.hosts --apply 'hosts: builtins.concatStringsSep " " (builtins.attrNames hosts)'); do
    if [[ $deployed = 1 ]]; then echo; fi
    deploy "$host"
    deployed=1
  done
fi
