{ pkgs }:

let
  # A minimal NixOS system used as the LXC template's rootfs.
  nixosLxc = import (pkgs.path + "/nixos") {
    inherit (pkgs) system;
    configuration =
      { ... }:
      {
        networking.hostName = "lxc-test";
        # The system is packaged as a container rootfs, never booted from a
        # disk, so the device names are placeholders. systemd skips the /
        # fstab entry when / is already mounted, which is always the case
        # inside the container.
        fileSystems."/" = {
          device = "/dev/lxc-root";
          fsType = "ext4";
        };
        boot.loader.grub.devices = [ "/dev/lxc-root" ];
        # lxc mounts /proc/sys read-only in the container, so this snippet
        # (which points the kernel at the NixOS modprobe wrapper) would fail
        # and make the activation script exit non-zero. It is meaningless in
        # a container anyway: the host kernel auto-loads modules, not the CT.
        # mkForce is required: a plain definition of this nested attribute
        # does not override the one from nixpkgs' modprobe.nix.
        system.activationScripts.modprobe.text = pkgs.lib.mkForce "";
        # Keep PID 1 alive so the container reports as running.
        systemd.services.lxc-keepalive = {
          description = "Keep the test container alive";
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;
          script = "true";
        };
      };
  };

  # Container init: lxc mounts /proc, /dev and /sys and provides a fresh
  # /run tmpfs. Run the NixOS activation script (which creates /etc with
  # the unit symlinks, /bin/sh, users and /run/current-system) and hand
  # over to systemd. All tools are referenced by absolute store path because
  # the container PATH does not contain /usr/bin.
  containerInit = pkgs.writeText "lxc-init" ''
    #!${pkgs.bashInteractive}/bin/bash
    set -e
    systemConfig=${nixosLxc.system}
    ${pkgs.coreutils}/bin/install -m 0755 -d /etc
    ${pkgs.coreutils}/bin/install -m 01777 -d /tmp
    # lxc mounts /proc/sys and /sys read-only, so activation snippets that
    # write to them (e.g. the firmware_class path) may fail depending on the
    # kernel. Like the standard NixOS stage-2 init, ignore the exit status
    # and only require the artifact systemd actually needs.
    $systemConfig/activate || true
    # The etc snippet creates /etc, including the unit symlinks systemd
    # loads from /etc/systemd/system. Require that artifact before handing
    # over to systemd.
    [ -d /etc/systemd/system ] || {
      echo "activation did not create /etc/systemd/system" >&2
      exit 1
    }
    exec /run/current-system/systemd/lib/systemd/systemd "$@"
  '';
in
{
  inherit (pkgs) lib;

  minimalIso = pkgs.fetchurl {
    url = "https://releases.nixos.org/nixos/24.05/nixos-24.05.7139.bcba2fbf6963/nixos-minimal-24.05.7139.bcba2fbf6963-x86_64-linux.iso";
    hash = "sha256-plre/mIHdIgU4xWU+9xErP+L4i460ZbcKq8iy2n4HT8=";
  };

  # A NixOS system packaged as an LXC template (rootfs tarball).
  #
  # The rootfs is NOT the toplevel itself: a toplevel is full of absolute
  # symlinks into /nix/store and lacks /sbin, so it cannot be extracted as a
  # bare rootfs. Instead, mirror the layout of a working NixOS LXC template:
  #   nix/store/  the system's full store closure (all absolute references
  #               inside the init/activation scripts resolve in-container)
  #   sbin/init   a script that runs the activation script (which sets up
  #               /etc with the unit symlinks and /run/current-system) and
  #               then execs systemd
  #   etc/        PVE's post-create hook writes into the rootfs before the
  #               first boot (e.g. /etc/hosts via set_hostname), so /etc must
  #               exist in the template even though the activation script
  #               would create it anyway
  lxcTemplate =
    let
      # Computes the system's full store closure outside the build sandbox
      # (nix-store cannot query the store database inside it) and exposes
      # it as a store-paths file.
      closureInfo = pkgs.closureInfo { rootPaths = [ nixosLxc.system ]; };
    in
    pkgs.stdenv.mkDerivation {
      pname = "nixos-lxc-template";
      version = "test";
      dontUnpack = true;
      dontBuild = true;
      installPhase = ''
          rootfs=$TMPDIR/rootfs
          mkdir -p $rootfs/sbin $rootfs/etc

          # Archive the full store closure. tar strips the leading /, so the
          # entries land under nix/store/ relative to the container root.
          ${pkgs.gnutar}/bin/tar --create \
            --files-from ${closureInfo}/store-paths \
            -f $TMPDIR/closure.tar

          install -m 0755 ${containerInit} $rootfs/sbin/init
          ${pkgs.gnutar}/bin/tar --append --file $TMPDIR/closure.tar -C $rootfs sbin/init etc

        ${pkgs.gzip}/bin/gzip -9 $TMPDIR/closure.tar
        mkdir -p $out
        mv $TMPDIR/closure.tar.gz $out/nixos-lxc-test.tar.gz
      '';
    };
}
