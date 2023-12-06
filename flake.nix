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
          wrapProgram $out/bin/deploy --set PATH ${with pkgs; lib.makeBinPath [coreutils bash nix git openssh]}
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
          };
          buildHost = mkOption {
            type = types.nullOr types.str;
            default = config.deploy-sh.targetHost;
          };
          buildCache = mkOption {
            type = types.nullOr types.str;
            default = null;
          };

          _config = mkOption {
            type = types.anything;
            visible = false;
            readOnly = true;
          };
        };

        config.deploy-sh._config = let
          vars = {
            inherit (config.deploy-sh) buildHost targetHost buildCache;
            systemDrv = config.system.build.toplevel.drvPath;
            system = config.system.build.toplevel.outPath;
            nomDrv = pkgs.nix-output-monitor.drvPath;
            nom = pkgs.nix-output-monitor.outPath;
          };
          text = builtins.concatStringsSep "" (lib.mapAttrsToList (k: v: "local ${k}=${lib.escapeShellArg v}\n") vars);
        in
          pkgs.writeText "deploy-sh-config" (builtins.unsafeDiscardStringContext text);
      };
  };
}
