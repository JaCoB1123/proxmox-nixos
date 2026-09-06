{ lib, ... }:

let
  cluster = import ./cluster-common.nix { inherit lib; };
in
{
  name = "pve-cluster";

  # Nodes start unclustered (seedSingleNode is disabled in cluster-common.nix)
  # so this test can build the cluster manually with pvecm + join.
  inherit (cluster) nodes;

  testScript = ''
    ${cluster.clusterSetupScript}
  '';
}
