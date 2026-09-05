{ pkgs, extraBaseModules }:

let
  testLib = import ./lib.nix { inherit pkgs; };
  runTest =
    modulePath: globalTimeout:
    let
      module = import modulePath;
      resolvedModule = if builtins.isFunction module then module testLib else module;
    in
    pkgs.testers.runNixOSTest {
      imports = [ resolvedModule ];
      inherit globalTimeout;
      extraBaseModules = {
        imports = builtins.attrValues extraBaseModules;
      };
    };
in
{
  test-pve-basic = runTest ./basic.nix (5 * 60);
  # test-pve-ceph = runTest ./ceph.nix (5 * 60);
  test-pve-cluster = runTest ./cluster.nix (5 * 60);
  test-pve-cluster-api-conntrack = runTest ./cluster-api-conntrack.nix (5 * 60);
  test-pve-cluster-conntrack = runTest ./cluster-conntrack.nix (5 * 60);
  test-pve-iso-upload = runTest ./iso-upload.nix (5 * 60);
  # The join itself runs under a 180s timeout(1) inside the test script, and
  # failure diagnostics add more; allow room for both plus convergence waits.
  test-pve-cluster-join = runTest ./cluster-join.nix (10 * 60);
  # Creating and starting several containers takes longer than the default,
  # especially since the template is a full NixOS system closure that must be
  # extracted into each container's disk.
  test-pve-lxc = runTest ./lxc.nix (20 * 60);
  test-pve-linstor = runTest ./linstor.nix (5 * 60);
  test-pve-reboot = runTest ./reboot.nix (5 * 60);
  test-pve-vm = runTest ./vm.nix (5 * 60);
}
