{
  inputs = {
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-libvncserver.url = "github:NixOS/nixpkgs/e6f23dc08d3624daab7094b701aa3954923c6bbb";
    utils.url = "github:numtide/flake-utils";
    flake-compat.url = "github:edolstra/flake-compat";
  };

  nixConfig.extra-substituters = "https://cache.saumon.network/proxmox-nixos";
  nixConfig.extra-trusted-public-keys = "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM=";

  description = "Proxmox on NixOS";

  outputs =
    {
      self,
      nixpkgs-stable,
      nixpkgs-libvncserver,
      utils,
      ...
    }:
    {
      nixosModules = import ./modules;
    }
    //
      utils.lib.eachSystem
        [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ]
        (
          system:
          let
            pkgs = import nixpkgs-stable {
              inherit system;
              overlays = [
                self.overlays.${system}
                (_: _: { inherit (nixpkgs-libvncserver.legacyPackages.${system}) libvncserver; })
                (final: prev: {
                  perl5 = prev.perl5 // {
                    pkgs = prev.perl5.pkgs.overrideScope (
                      final2: prev2: {
                        XMLTwig = prev2.XMLTwig.overrideAttrs (_: {
                          version = "3.54";
                          src = builtins.fetchurl {
                            url = "https://cpan.metacpan.org/authors/id/M/MI/MIROD/XML-Twig-3.54.tar.gz";
                            sha256 = "0b744a9737a070f95c32154afd526bf5ebe76a59feb8bc1f5dbc6cdaa5e0e529";
                          };
                        });
                        NetDBus = prev2.NetDBus.overrideAttrs (_: {
                          propagatedBuildInputs = [ final2.XMLTwig ];
                        });
                      }
                    );
                  };
                })
              ];
            };
          in
          {
            overlays = _: _: (import ./pkgs { inherit pkgs; });

            packages = utils.lib.filterPackages system (import ./pkgs { inherit pkgs; });

            checks =
              if (system == "x86_64-linux") then
                (
                  self.packages.${system}
                  // (import ./tests {
                    inherit pkgs;
                    extraBaseModules = self.nixosModules;
                  })
                )
              else
                { };
          }
        );
}
