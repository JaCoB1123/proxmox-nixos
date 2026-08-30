{
  config,
  lib,
  pkgs,
  ...
}:

lib.mkIf config.services.proxmox-ve.enable {
  systemd.services = {
    # PVE's start/stop code waits for container state changes on lxc's
    # monitor socket (PVE::LXC::Monitor), which is created by lxc-monitord.
    # Without it every CT start/stop logs "failed to connect to monitor
    # socket" and pct start races the container startup. --daemon runs it
    # persistently in the foreground (Type=simple); the lxcpath must match
    # the one PVE assumes (/var/lib/lxc, its monitor socket name is a hash
    # of that path).
    lxc-monitord = {
      description = "LXC Container Monitoring Daemon";
      wantedBy = [ "multi-user.target" ];
      before = [ "pve-guests.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.lxc}/libexec/lxc/lxc-monitord --daemon /var/lib/lxc";
        Restart = "on-failure";
      };
    };

    # The pve-lxc-syscalld daemon (needed for the experimental 'mknod' CT
    # feature) is not built by the pve-container derivation, so this unit
    # would fail at boot. Re-enable it once the daemon is packaged:
    #
    # pve-lxc-syscalld = {
    #   description = "Proxmox VE LXC Syscall Daemon";
    #   wantedBy = [ "multi-user.target" ];
    #   before = [ "pve-guests.service" ];
    #   serviceConfig = {
    #     Type = "notify";
    #     ExecStart = "${pkgs.pve-container}/lib/pve-lxc-syscalld/pve-lxc-syscalld --system /run/pve/lxc-syscalld.sock";
    #     RuntimeDirectory = "pve";
    #     Restart = "on-failure";
    #   };
    # };

    "pve-container-debug@" = {
      # based on lxc@.service, but without an install section because
      # starting and stopping should be initiated by PVE code, not
      # systemd.
      description = "PVE LXC Container: %i";
      after = [ "lxc.service" ];
      wants = [ "lxc.service" ];
      unitConfig = {
        DefaultDependencies = false;
        Documentation = "man:lxc-start man:lxc man:pct";
      };
      serviceConfig = {
        Type = "simple";
        Delegate = true;
        KillMode = "mixed";
        TimeoutStopSec = 120;
        ExecStart = "${pkgs.lxc}/bin/lxc-start -F -n %i -o /dev/stderr -l DEBUG";
        ExecStop = "${pkgs.pve-container}/share/lxc/pve-container-stop-wrapper %i";
        # Environment=BOOTUP=serial
        # Environment=CONSOLETYPE=serial
        # Prevent container init from putting all its output into the journal
        StandardOutput = null;
        StandardError = "file:/run/pve/ct-%i.stderr";
      };
      # The stop wrapper execs systemctl and lxc-stop via PATH.
      environment = {
        PATH = "${pkgs.lxc}/bin:${pkgs.systemd}/bin";
      };
    };

    "pve-container@" = {
      # based on lxc@.service, but without an install section because
      # starting and stopping should be initiated by PVE code, not
      # systemd.
      description = "PVE LXC Container: %i";
      after = [ "lxc.service" ];
      wants = [ "lxc.service" ];
      unitConfig = {
        DefaultDependencies = false;
        Documentation = "man:lxc-start man:lxc man:pct";
      };
      serviceConfig = {
        Type = "simple";
        Delegate = true;
        KillMode = "mixed";
        TimeoutStopSec = 120;
        ExecStart = "${pkgs.lxc}/bin/lxc-start -F -n %i";
        ExecStop = "${pkgs.pve-container}/share/lxc/pve-container-stop-wrapper %i";
        # Environment=BOOTUP=serial
        # Environment=CONSOLETYPE=serial
        # Prevent container init from putting all its output into the journal
        StandardOutput = null;
        StandardError = "file:/run/pve/ct-%i.stderr";
      };
      # The stop wrapper execs systemctl and lxc-stop via PATH.
      environment = {
        PATH = "${pkgs.lxc}/bin:${pkgs.systemd}/bin";
      };
    };
  };
}
