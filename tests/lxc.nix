{ lxcTemplate, ... }:

{
  name = "pve-lxc";

  nodes.mypve = {
    services.proxmox-ve = {
      enable = true;
      ipAddress = "192.168.1.1";
      bridges = [ "vmbr0" ];
    };

    networking.bridges.vmbr0.interfaces = [ ];

    virtualisation = {
      additionalPaths = [ lxcTemplate ];
      # The template is a full NixOS system closure that must be extracted
      # into each container's disk, which is CPU- and IO-intensive.
      cores = 4;
      diskSize = 16384;
      memorySize = 4096;
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("pveproxy.service")
    assert "running" in machine.succeed("pveproxy status")

    # Install the LXC template
    machine.succeed("mkdir -p /var/lib/vz/template/cache/")
    machine.succeed("cp ${lxcTemplate}/nixos-lxc-test.tar.gz /var/lib/vz/template/cache/nixos-test.tar.gz")

    hostname = machine.succeed("hostname").strip()

    # PVE resolves --ostemplate via PVE::Storage::abs_filesystem_path, which
    # only accepts a volume ID or an existing file path, so use the absolute
    # cache path (a bare filename would not resolve against the daemon CWD).
    tmpl = "/var/lib/vz/template/cache/nixos-test.tar.gz"

    def assert_created(vmid):
        # pvesh exits 0 even when the job fails, so verify the CT actually
        # exists. The real error from a failed post-create hook goes to the
        # pveproxy journal (the chrooted child's stderr).
        try:
            machine.succeed(f"test -f /etc/pve/lxc/{vmid}.conf")
        except Exception:
            print(machine.succeed("journalctl -u pveproxy --no-pager | tail -30"))
            raise

    # Privileged CT with a veth, via the in-process CLI path (pct).
    # PVE 9.x defaults new CTs to unprivileged, so set it explicitly.
    machine.succeed(
      f"pct create 101 {tmpl} --rootfs local:4 --password secret --unprivileged 0 --cores 1 --memory 1024 --swap 512 --hostname ct101 --net0 name=eth0,bridge=vmbr0",
    )
    assert_created(101)
    machine.succeed("pct start 101")
    machine.wait_until_succeeds("pct status 101 | grep -F 'status: running'")
    machine.succeed("pct stop 101")
    machine.wait_until_succeeds("pct status 101 | grep -F 'status: stopped'")

    # Privileged CT via the daemon path (pvesh -> pveproxy, as the web UI does)
    machine.succeed(
      f"pvesh create /nodes/{hostname}/lxc --vmid 102 --ostemplate {tmpl} --rootfs local:4 --password secret --unprivileged 0 --cores 1 --memory 1024 --swap 512 --hostname ct102",
    )
    assert_created(102)
    machine.succeed(f"pvesh create /nodes/{hostname}/lxc/102/status/start")
    machine.wait_until_succeeds("pct status 102 | grep -F 'status: running'")
    machine.succeed(f"pvesh create /nodes/{hostname}/lxc/102/status/stop")
    machine.wait_until_succeeds("pct status 102 | grep -F 'status: stopped'")

    # Unprivileged CT (subuid/subgid mapping via newuidmap)
    machine.succeed(
      f"pct create 103 {tmpl} --rootfs local:4 --password secret --unprivileged 1 --cores 1 --memory 1024 --swap 512 --hostname ct103",
    )
    assert_created(103)
    machine.succeed("pct start 103")
    machine.wait_until_succeeds("pct status 103 | grep -F 'status: running'")
    machine.succeed("pct stop 103")
    machine.wait_until_succeeds("pct status 103 | grep -F 'status: stopped'")

    # Cleanup
    machine.succeed("pct destroy 101", "pct destroy 102", "pct destroy 103")
  '';
}
