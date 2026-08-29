{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.services.proxmox-ve;
in

{
  meta.maintainers = with maintainers; [
    julienmalka
    camillemndn
  ];

  imports = [
    ./ceph.nix
    ./bridges.nix
    ./cluster.nix
    ./container.nix
    # ./firewall.nix
    # ./ha-manager.nix
    ./linstor.nix
    ./manager.nix
    ./qemu-server.nix
    ./rrdcached.nix
    ./vms.nix
  ];

  options.services.proxmox-ve = {
    enable = mkEnableOption "Proxmox VE";

    package = mkPackageOption pkgs "proxmox-ve" { };

    ipAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        The IP address used to reach this Proxmox node from outside, added to "/etc/hosts" file.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open port in firewall for proxmox-admin (8006), rpcbind (111) and http(s) (80,443)
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      boot.supportedFilesystems = [
        "fuse"
        "glusterfs"
      ];

      networking.hosts = {
        "127.0.0.2" = lib.mkForce [ ];
        "::1" = lib.mkForce [ ];
        "${cfg.ipAddress}" = [ config.networking.hostName ];
      };

      # create the /etc/network/interfaces file for proxmox
      systemd.tmpfiles.rules = [
        "d /etc/network 0755 root root -"
        "f /etc/network/interfaces 0755 root root -"
      ];

      services.openssh = {
        enable = true;
        settings.AcceptEnv =
          if lib.versionAtLeast pkgs.lib.version "26.05pre-git" then
            [
              "LANG"
              "LC_*"
            ]
          else
            "LANG LC_*";
      };
      programs.ssh.extraConfig = ''
        Host *
          SendEnv LANG LC_*
      '';

      security.pam.services."proxmox-ve-auth" = {
        logFailures = true;
        nodelay = true;
      };

      services.rpcbind.enable = true;
      services.rrdcached.enable = true;

      users.users.www-data = {
        isSystemUser = true;
        group = "www-data";
      };
      users.groups.www-data = { };

      # Subuid/subgid ranges for unprivileged LXC containers. PVE maps a CT's
      # root (uid 0) into the invoking user's subuid/subgid range, and
      # newuidmap/newgidmap refuse to run unless those ranges are declared for
      # that user. Give root the standard 100000:65536 range so unprivileged CTs
      # work out of the box; override users.users.root.subUidRanges/subGidRanges
      # (or add ranges for other users) to change this.
      users.users.root = {
        subUidRanges = mkDefault [
          {
            count = 65536;
            startUid = 100000;
          }
        ];
        subGidRanges = mkDefault [
          {
            count = 65536;
            startGid = 100000;
          }
        ];
      };

      environment.systemPackages = [ cfg.package ];
      environment.etc.issue.enable = false;

      networking.firewall = mkIf cfg.openFirewall {
        allowedTCPPorts = [
          80
          111
          443
          8006
        ];
        allowedUDPPorts = [ 111 ];
        allowedUDPPortRanges = [
          {
            from = 5405;
            to = 5412;
          }
        ];
      };
    }
  ]);
}
