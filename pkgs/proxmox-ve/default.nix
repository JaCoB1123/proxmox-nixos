{
  lib,
  buildEnv,
  lxc,
  runCommand,
  linstor-client,
  pve-access-control,
  pve-cluster,
  pve-container,
  pve-firewall,
  pve-ha-manager,
  pve-manager,
  pve-qemu-server,
  pve-storage,
  termproxy,
  vncterm,
  wget,
  util-linux,
  enableLinstor ? false,
}:

buildEnv rec {
  name = "proxmox-ve-${pve-manager.version}";

  paths = [
    # Only the lxc tools (bin/) go on the system PATH; the full lxc package
    # would collide with the share/lxc files that pve-container bundles in
    # the buildEnv merge. PVE's perl code shells out to these (lxc-info,
    # lxc-stop, ...), and PVE::VZDump::check_bin scans $PATH directly.
    (runCommand "lxc-${lxc.version}-bin" { } ''
      mkdir -p $out/bin
      ln -s ${lxc}/bin/* $out/bin/
    '')
    pve-access-control
    pve-cluster
    (pve-container.override { inherit enableLinstor; })
    pve-firewall
    (pve-ha-manager.override { inherit enableLinstor; })
    (pve-manager.override { inherit enableLinstor; })
    pve-qemu-server
    (pve-storage.override { inherit enableLinstor; })
    termproxy
    vncterm
    wget
    util-linux
  ]
  ++ lib.optionals enableLinstor [ linstor-client ];

  meta = with lib; {
    description = "A complete, open-source server management platform for enterprise virtualization";
    homepage = "https://proxmox.com/proxmox-virtual-environment/";
    license = concatMap (pkg: toList (pkg.meta.license or [ ])) paths;
    maintainers = with maintainers; [
      camillemndn
      julienmalka
    ];
    platforms = platforms.linux;
  };
}
