#!/usr/bin/env bash

set -e

log() {
  local prefix=""
  if [[ -n "$host" ]]; then
    prefix="[$host] "
  fi
  echo -e "\e[1m${2:-\e[34m}$prefix$1\e[0m"
}

sshHost() { echo "${1%:*}"; }
sshPort() { [[ "$1" =~ :[0-9]+$ ]] && echo "-p${1##*:}" || echo -p22; }
nixSshHost() { echo "ssh://$(sshHost $1)"; }
nixSshPort() { echo "NIX_SSHOPTS=$(sshPort $1)"; }

nix="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

deploy() {
  host="$1"
  trap "log 'Deployment of $host failed!' \"\e[31m\"" ERR

  log "Starting deployment of $host" "\e[33m"
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

  if [[ "$action" = "diff" ]]; then
    log "Copying current derivation from target host $targetHost"
    if ! currentDrv=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") nix-store --query --deriver /run/current-system); then
      log "Failed to lookup current system on $targetHost" "\e[31m"
      return 1
    fi

    if [[ "$currentDrv" = "$systemDrv" ]]; then
      log "Current and new configuration are the same" "\e[32m"
      return
    fi

    if ! [[ -e "$currentDrv" ]] && ! env $(nixSshPort "$targetHost") $nix copy --derivation --from $(nixSshHost "$targetHost") "$currentDrv^*"; then
      if [[ -z "$buildHost" ]] || [[ "$targetHost" = "$buildHost" ]]; then
        log "Failed to fetch current system from $targetHost" "\e[31m"
        return 1
      fi

      log "Failed to fetch current system from $targetHost" "\e[33m"
      if ! env $(nixSshPort "$buildHost") $nix copy --derivation --from $(nixSshHost "$buildHost") "$currentDrv^*"; then
        log "Failed to fetch current system from $buildHost" "\e[31m"
        return 1
      fi
    fi

    log "Current and new configuration differ:" "\e[33m"
    nix-diff "$currentDrv" "$systemDrv"
    return
  fi

  if [[ -z "$buildHost" ]]; then
    log "Building locally, then deploying to $targetHost" "\e[36m"
  elif [[ "$buildHost" = "$targetHost" ]]; then
    log "Building and deploying to $targetHost" "\e[36m"
  else
    log "Building on $buildHost, then deploying to $targetHost" "\e[36m"
  fi
  if [[ -n "$buildCache" ]]; then
    if [[ -z "$buildHost" ]]; then
      log "Cache the system at $buildCache" "\e[36m"
    else
      log "Cache the system on $buildHost at $buildCache" "\e[36m"
    fi
  fi
  log "System path: $system" "\e[0m"
  log "System derivation: $systemDrv" "\e[0m"

  local nomPipe="--log-format internal-json -v |& $nom/bin/nom --json"

  if [[ "$buildHost" != "$targetHost" ]] && [[ "$pushDerivations" = "1" ]]; then
    log "Copying derivations to target host $targetHost"
    env $(nixSshPort "$targetHost") $nix copy --derivation --to $(nixSshHost "$targetHost") "$systemDrv^*"
  fi

  if [[ -n "$buildHost" ]]; then
    log "Copying derivations to build host $buildHost"
    env $(nixSshPort "$buildHost") $nix copy --derivation --to $(nixSshHost "$buildHost") "$systemDrv^*" "$nomDrv^*"

    if [[ $fetch = 1 ]] && [[ "$targetHost" != "$buildHost" ]]; then
      if oldSystem=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") readlink /run/current-system); then
        log "Fetching old system from $targetHost"
        ssh $(sshPort "$buildHost") $(sshHost "$buildHost") env $(nixSshPort "$targetHost") $nix copy --no-check-sigs --from $(nixSshHost "$targetHost") "$oldSystem"
      else
        log "Failed to lookup current system on $targetHost" "\e[31m"
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
        log "Failed to lookup current system on $targetHost" "\e[31m"
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

  log "Deployment of $host succeeded!" "\e[32m"
}

for arg in $@; do
  if [[ "$arg" =~ ^(-h|--help)$ ]]; then
    echo -e "Simple NixOS remote deployment tool (\e[36mhttps://github.com/Defelo/deploy-sh\e[0m)"
    echo -e
    echo -e "\e[1m\e[32mUsage: \e[36mdeploy [OPTIONS] [HOSTS]...\e[0m"
    echo -e
    echo -e "For each host, only the most recent options to its left are taken into account. For"
    echo -e "example, \`\e[36mdeploy --local foo bar --remote baz\e[0m\` will build hosts foo and bar locally,"
    echo -e "and only baz on a remote build host."
    echo -e "All hosts are deployed if no host is specified explicitly."
    echo -e
    echo -e "\e[1m\e[32mActivation options:\e[0m"
    echo -e "\e[1m\e[36m  --switch       \e[0m Build and activate the new configuration, and make it the boot default. (default)"
    echo -e "\e[1m\e[36m  --boot         \e[0m Build the new configuration and make it the boot default, but do not activate it."
    echo -e "\e[1m\e[36m  --test         \e[0m Build and activate the new configuration, but do not add it to the boot menu."
    echo -e "\e[1m\e[36m  --dry-activate \e[0m Build the new configuration, but do not activate it."
    echo -e "\e[1m\e[36m  --reboot       \e[0m Build the new configuration, make it the boot default and reboot into the new system."
    echo -e "\e[1m\e[36m  --diff         \e[0m Display differences between the current and new configuration, but do not activate it."
    echo -e
    echo -e "\e[1m\e[32mHost options:\e[0m"
    echo -e "\e[1m\e[36m  --local        \e[0m Build the configuration locally and copy the new system to the target host."
    echo -e "\e[1m\e[36m  --remote       \e[0m Build the configuration on the remote build host."
    echo -e "\e[1m\e[36m  --build-host   \e[0m Set the host to build the configuration on."
    echo -e "\e[1m\e[36m  --target-host  \e[0m Set the host to deploy the system on."
    echo -e
    echo -e "\e[1m\e[32mBuild options:\e[0m"
    echo -e "\e[1m\e[36m  --cache        \e[0m Set a path on the build host where to store a symlink to the new system to avoid garbage collection."
    echo -e "\e[1m\e[36m  --no-cache     \e[0m Don't store a symlink to the new system on the build host."
    echo -e "\e[1m\e[36m  --fetch        \e[0m Copy the current system of the target host to the build host before building."
    echo -e "\e[1m\e[36m  --no-fetch     \e[0m Don't copy the current system of the target host to the build host before building. (default)"
    echo -e
    echo -e "\e[1m\e[32mOptions:\e[0m"
    echo -e "\e[1m\e[36m  -h  --help     \e[0m Print help"
    exit
  fi
done

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
    --switch|--boot|--test|--dry-activate|--reboot|--diff)
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
    -*)
      echo -e "\e[1m\e[31mUnknown flag: $i\e[0m"
      echo -e "For more information, try '\e[1m\e[36m--help\e[0m'."
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
