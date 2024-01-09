# deploy-sh
Simple NixOS remote deployment tool

## Flake Setup
<details>
  <summary>
    <b>1.</b> Add a <code>deploy-sh.hosts</code> output to your <code>flake.nix</code>. This has to be an attribute set of NixOS systems.
  </summary>

  ```nix
  {
    outputs = {self, nixpkgs, ...}: {
      nixosConfigurations = {
        foo = nixpkgs.lib.nixosSystem { ... };
        bar = nixpkgs.lib.nixosSystem { ... };
        baz = nixpkgs.lib.nixosSystem { ... };
      };
      deploy-sh.hosts = self.nixosConfigurations;
    };
  }
  ```
</details>

<details>
  <summary>
    <b>2.</b> Import and configure the <code>deploy-sh</code> NixOS module.
  </summary>

  ```nix
  {
    inputs = {
      deploy-sh = "github:Defelo/deploy-sh";
    };
    outputs = {self, nixpkgs, deploy-sh, ...}: {
      nixosConfigurations.foo = nixpkgs.lib.nixosSystem {
        # ...
        modules = [
          # ...
          deploy-sh.nixosModules.default
          {
            deploy-sh.targetHost = "root@10.13.37.2";
          }
        ];
      };
      deploy-sh.hosts = self.nixosConfigurations;
    };
  }
  ```
</details>

<details>
  <summary>
    <b>3.</b> To be able to use the <code>deploy</code> command, add <code>deploy-sh</code> to your dev shell.
  </summary>

  ```nix
  {
    inputs = {
      deploy-sh = "github:Defelo/deploy-sh";
    };
    outputs = {self, nixpkgs, deploy-sh, ...}: let
      system = "x86_64-linux";
      pkgs = import nixpkgs {inherit system;};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          deploy-sh.packages.${system}.default
        ];
      };
    };
  }
  ```
</details>

## NixOS Module Options
See [flake.nix](https://github.com/Defelo/deploy-sh/blob/develop/flake.nix#L48-L70)

## Usage
```
$ nix develop  # if you are not using direnv
$ deploy --help
Simple NixOS remote deployment tool (https://github.com/Defelo/deploy-sh)

Usage: deploy [OPTIONS] [HOSTS]...

For each host, only the most recent options to its left are taken into account. For
example, `deploy --local foo bar --remote baz` will build hosts foo and bar locally,
and only baz on a remote build host.
All hosts are deployed if no host is specified explicitly.

Activation options:
  --switch        Build and activate the new configuration, and make it the boot default. (default)
  --boot          Build the new configuration and make it the boot default, but do not activate it.
  --test          Build and activate the new configuration, but do not add it to the boot menu.
  --dry-activate  Build the new configuration, but do not activate it.
  --reboot        Build the new configuration, make it the boot default and reboot into the new system.
  --diff          Display differences between the current and new configuration, but do not activate it.
  --nvd           Display package version differences between the current and new configuration, but do not activate it.

Host options:
  --local         Build the configuration locally and copy the new system to the target host.
  --remote        Build the configuration on the remote build host.
  --build-host    Set the host to build the configuration on.
  --target-host   Set the host to deploy the system on.

Build options:
  --cache         Set a path on the build host where to store a symlink to the new system to avoid garbage collection.
  --no-cache      Don't store a symlink to the new system on the build host.
  --fetch         Copy the current system of the target host to the build host before building.
  --no-fetch      Don't copy the current system of the target host to the build host before building. (default)

Options:
  -h  --help      Print help
```
