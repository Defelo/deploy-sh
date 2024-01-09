{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    nixpkgs,
    self,
  }: let
    defaultSystems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    eachDefaultSystem = f:
      builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        })
        defaultSystems);
  in {
    packages = eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      default = pkgs.stdenvNoCC.mkDerivation {
        pname = "deploy-sh";
        version = "0.2.0";
        nativeBuildInputs = [pkgs.makeWrapper];
        unpackPhase = "true";
        installPhase = ''
          install -DT ${./deploy.sh} $out/bin/deploy
        '';
        postFixup = ''
          wrapProgram $out/bin/deploy --set PATH ${with pkgs; lib.makeBinPath [coreutils bash nix git openssh nix-diff]}
        '';
      };
    });

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }:
      with lib; {
        options.deploy-sh = {
          targetHost = mkOption {
            type = types.str;
            example = "root@10.13.37.2";
            description = lib.mdDoc ''
              The host to deploy the system on. Both the local host and the build host has to be able to connect to this host via SSH.
            '';
          };
          buildHost = mkOption {
            type = types.nullOr types.str;
            default = config.deploy-sh.targetHost;
            example = "root@10.13.37.3";
            description = lib.mdDoc ''
              The host to build the system on. The local host has to be able to connect to this host via SSH.
            '';
          };
          buildCache = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/var/cache/deploy-sh/HOSTNAME";
            description = lib.mdDoc ''
              A path on the build host where to store a symlink to the new system to avoid garbage collection.
            '';
          };
          enableDiff = mkOption {
            type = types.bool;
            default = true;
          };
          pushDerivations = mkOption {
            type = types.bool;
          };

          _config = mkOption {
            type = types.anything;
            visible = false;
            readOnly = true;
          };
        };

        config = let
          cfg = config.deploy-sh;
        in {
          deploy-sh.pushDerivations = lib.mkDefault cfg.enableDiff;
          deploy-sh._config = let
            vars = {
              inherit (cfg) buildHost targetHost buildCache pushDerivations;
              systemDrv = config.system.build.toplevel.drvPath;
              system = config.system.build.toplevel.outPath;
              nomDrv = pkgs.nix-output-monitor.drvPath;
              nom = pkgs.nix-output-monitor.outPath;
            };
            text = builtins.concatStringsSep "" (lib.mapAttrsToList (k: v: "local ${k}=${lib.escapeShellArg v}\n") vars);
          in
            pkgs.writeText "deploy-sh-config" (builtins.unsafeDiscardStringContext text);

          nix.settings.keep-derivations = lib.mkIf cfg.enableDiff true;
        };
      };
  };
}
