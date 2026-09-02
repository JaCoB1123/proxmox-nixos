{ lib, ... }:

let
  cluster = import ./cluster-common.nix { inherit lib; };
in
{
  name = "pve-cluster";

  # This test creates the cluster manually with pvecm (see clusterSetupScript),
  # so disable the default single-node seeding that would otherwise pre-create a
  # cluster on each node before the manual `pvecm create`.
  nodes = lib.mapAttrs (_: cfg: { config, ... }: {
    imports = [ cfg ];
    services.proxmox-ve.seedSingleNode = false;
  }) cluster.nodes;

  testScript = ''
    ${cluster.clusterSetupScript}
  '';
}
