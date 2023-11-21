{
  outputs = {self}: {
    lib.mkDeploy = {
      hosts,
      pkgs,
    }: let
      inherit (builtins) concatStringsSep;
      inherit (pkgs.lib) mapAttrsToList escapeShellArg optionalString;
      mkDeploy = command:
        pkgs.writeShellScript "deploy-${command}" ''
          export PATH=${pkgs.nixos-rebuild}/bin:$PATH

          declare -A deploy_commands=(
          ${concatStringsSep "\n" (
            mapAttrsToList (k: v: let
              cfg = v.config.deploy-sh;
              cmd = "nixos-rebuild ${command} --flake ${escapeShellArg ".#${k}"} --target-host ${escapeShellArg cfg.targetHost} ${optionalString (cfg.buildHost != null) "--build-host ${escapeShellArg cfg.buildHost}"}";
            in "  [${escapeShellArg k}]=${escapeShellArg cmd}")
            hosts
          )}
          )

          fst=1
          deploy() {
            [[ $fst = 0 ]] && echo; fst=0
            cmd="''${deploy_commands["$1"]}"
            if [[ -z "$cmd" ]]; then
              echo -e "\033[1m\033[31mHost '$1' not found!\033[0m"
              exit 1
            else
              echo -e "\033[1mDeploying host '$1'\033[0m"
              echo -e "+ $cmd"
              if eval "$cmd"; then
                echo -e "\033[1m\033[32mHost '$1' successfully deployed!\033[0m"
              else
                echo -e "\033[1m\033[31mDeployment of host '$1' failed!\033[0m"
                exit 2
              fi
            fi
          }

          if [[ $# -eq 0 ]]; then
          ${concatStringsSep "\n" (mapAttrsToList (k: v: "  deploy ${escapeShellArg k}") hosts)}
          else
            for host in $@; do
              deploy "$host"
            done
          fi
        '';
    in
      pkgs.stdenv.mkDerivation {
        name = "deploy-sh";
        unpackPhase = "true";
        installPhase = ''
          mkdir -p $out/bin;
          cp ${mkDeploy "switch"} $out/bin/deploy
          cp ${mkDeploy "test"} $out/bin/deploy-test
          cp ${mkDeploy "boot"} $out/bin/deploy-boot
        '';
      };
    nixosModules.default = {
      config,
      lib,
      ...
    }:
      with lib; {
        options.deploy-sh = {
          targetHost = mkOption {
            type = types.str;
          };
          buildHost = mkOption {
            type = types.nullOr types.str;
            default = config.deploy-sh.targetHost;
          };
        };
        config = {};
      };
  };
}
