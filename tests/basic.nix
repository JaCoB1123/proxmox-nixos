{
  name = "pve-basic";

  nodes.mypve = {
    services.proxmox-ve = {
      enable = true;
      ipAddress = "192.168.1.1";
    };

    # The PVE daemons (pvedaemon, pveproxy, pvestatd, corosync) need more
    # than the 1024 MiB default
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("pveproxy.service")
    assert "running" in machine.succeed("pveproxy status")
    assert "Proxmox" in machine.succeed("curl -k https://localhost:8006")
    # The single-node cluster is seeded at boot (services.proxmox-ve.seedSingleNode)
    machine.wait_for_unit("corosync.service")
    machine.wait_until_succeeds("pvecm status | grep -E 'Quorate:[[:space:]]+Yes'")
  '';
}
