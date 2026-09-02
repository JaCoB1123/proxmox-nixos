{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.proxmox-ve;
in

lib.mkIf cfg.enable {
  systemd.services = {
    pve-cluster = {
      description = "The Proxmox VE cluster filesystem";
      wants = [
        "corosync.service"
        #"rrdcached.service"
        #"shutdown.target"
      ];
      after = [
        "network.target"
        "sys-fs-fuse-connections.mount"
        "time-sync.target"
        #"rrdcached.service"
      ];
      before = [
        "corosync.service"
        "cron.service"
      ];
      #unitConfig = {
      #  DefaultDependencies = false;
      #  Conflicts = [ "shutdown.target" ];
      #};
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/pmxcfs";
        KillMode = "mixed";
        Restart = "on-failure";
        TimeoutStopSec = 10;
        Type = "forking";
        PIDFile = "/run/pve-cluster.pid";
      };
    };

    # Seeds a single-node corosync.conf into the PVE cluster filesystem
    # (like a stock Proxmox install has) so that pve-clusterd and the
    # web UI can report node/VM/storage status. Only written when missing,
    # so a real multi-node cluster created later via pvecm is untouched.
    "pve-corosync-conf" = lib.mkIf cfg.seedSingleNode (
      let
        corosyncConf = pkgs.writeText "corosync.conf" ''
          logging {
            debug: off
            to_syslog: yes
          }

          nodelist {
            node {
              name: ${config.networking.hostName}
              nodeid: 1
              quorum_votes: 1
              ring0_addr: ${cfg.ipAddress}
            }
          }

          quorum {
            provider: corosync_votequorum
          }

          totem {
            cluster_name: proxmox
            config_version: 1
            interface {
              bindnetaddr: ${cfg.ipAddress}
              ringnumber: 0
            }
            ip_version: ipv4
            secauth: on
            version: 2
          }
        '';
      in
      {
        description = "Seed single-node corosync.conf into the PVE cluster filesystem";
        after = [ "pve-cluster.service" ];
        wants = [ "pve-cluster.service" ];
        script = ''
          [ -f /etc/pve/corosync.conf ] || cp ${corosyncConf} /etc/pve/corosync.conf
          ln -sf /etc/pve/corosync.conf /etc/corosync/corosync.conf
          # secauth: on requires an authkey of at least 1024 bits, readable only by root
          if [ ! -f /etc/corosync/authkey ]; then
            { head -c 128 /dev/urandom | od -An -tx1 | tr -d " \n"; echo; } > /etc/corosync/authkey.tmp
            chmod 0600 /etc/corosync/authkey.tmp
            mv /etc/corosync/authkey.tmp /etc/corosync/authkey
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      }
    );

    corosync = {
      description = "Corosync Cluster Engine";
      requires = [ "network-online.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optionals cfg.seedSingleNode [ "pve-corosync-conf.service" ];
      wants = lib.optionals cfg.seedSingleNode [ "pve-corosync-conf.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        ConditionKernelCommandLine = "!nocluster";
        ConditionPathExists = "/etc/corosync/corosync.conf";
      };
      serviceConfig = {
        # -f keeps corosync in the foreground so Type=notify works
        ExecStart = "${pkgs.corosync}/bin/corosync -f";
        ExecStop = "${pkgs.corosync}/bin/corosync-cfgtool -H --force";
        Type = "notify";
        StateDirectory = "corosync";

        # In typical systemd deployments, both standard outputs are forwarded to
        # journal (stderr is what's relevant in the pristine corosync configuration),
        # which hazards a message redundancy since the syslog stream usually ends there
        # as well; before editing this line, you may want to check DefaultStandardError
        # in systemd-system.conf(5) and whether /dev/log is a systemd related symlink.
        StandardError = "null";

        # The following config is for corosync with enabled watchdog service.
        #
        #  When corosync watchdog service is being enabled and using with
        #  pacemaker.service, and if you want to exert the watchdog when a
        #  corosync process is terminated abnormally,
        #  uncomment the line of the following Restart= and RestartSec=.
        #Restart=on-failure
        #  Specify a period longer than soft_margin as RestartSec.
        #RestartSec=70
        #  rewrite according to environment.
        #ExecStartPre=/sbin/modprobe softdog
        PrivateTmp = "yes";
      };
    };
  };

  systemd.tmpfiles.rules = [ "d /etc/corosync 0755 root root -" ];
}
