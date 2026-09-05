{
  name = "pve-cluster-join";

  nodes = {
    pve1 =
      { pkgs, ... }:
      {
        services.proxmox-ve = {
          enable = true;
          ipAddress = "192.168.1.1";
        };

        environment.systemPackages = [ pkgs.openssl ];

        users.users.root = {
          password = "mypassword";
          initialPassword = null;
          hashedPassword = null;
          hashedPasswordFile = null;
        };

        # 2 vCPU per node: the join restarts corosync + pmxcfs and reloads
        # pveproxy on both nodes at once, which starves a 1-vCPU VM and kills
        # the virtio-console backdoor with an I/O error mid-join.
        virtualisation = {
          cores = 2;
          memorySize = 2048;
        };
      };

    pve2 = {
      services.proxmox-ve = {
        enable = true;
        ipAddress = "192.168.1.2";
      };

      # Match pve1: see the comment there on why 1 vCPU is not enough.
      virtualisation = {
        cores = 2;
        memorySize = 2048;
      };
    };
  };

  testScript = ''
    pve1.start()
    pve2.start()
    pve1.wait_for_unit("pveproxy.service")
    pve1.wait_for_unit("sshd.service")
    pve2.wait_for_unit("sshd.service")
    assert "running" in pve1.succeed("pveproxy status")
    assert "Proxmox" in pve1.succeed("curl -k https://localhost:8006")

    # Both nodes boot into their own seeded single-node cluster
    # (services.proxmox-ve.seedSingleNode)
    pve1.wait_for_unit("corosync.service")
    pve2.wait_for_unit("corosync.service")
    pve1.wait_until_succeeds("pvecm status | grep -E 'Quorate:[[:space:]]+Yes'")
    pve2.wait_until_succeeds("pvecm status | grep -E 'Quorate:[[:space:]]+Yes'")

    # The realistic join flow: the joining node initiates the join,
    # replacing its own single-node cluster with the existing one.
    # Stop pve2's corosync first: the seeded single-node cluster is a
    # placeholder, and finish_join starts corosync with the new two-node
    # config. Leaving it running during the join starves the 1-vCPU test
    # VM (corosync + pmxcfs restart + pveproxy reload all at once) and
    # kills the virtio-console backdoor channel with an I/O error.
    pve2.succeed("systemctl stop corosync")

    # --force is required because pve2 still has local cluster state
    # (its seeded corosync.conf/authkey); without it PVE's assert_joinable
    # refuses to join. With force, the join overwrites the local config and
    # replaces the local CFS database. --link0 pins pve2's cluster address:
    # without it PVE falls back to resolving the node hostname, which picks
    # up the test VMs' IPv6 address that corosync 3.1.9 cannot parse as a
    # bindnet address.
    def dump_cluster_state():
        # Every command is bounded with timeout(1): a deadlocked pmxcfs makes
        # any /etc/pve (FUSE) access hang forever, and the diagnostics must
        # not share that fate.
        for m in (pve1, pve2):
            for cmd in [
                "timeout 5 ps -eo pid,ppid,stat,wchan:25,comm | head -40 || true",
                "timeout 5 cat /proc/loadavg || true",
                "timeout 5 sh -c 'ls /etc/pve/ >/dev/null 2>&1 && echo FUSE-OK || echo FUSE-HUNG' || true",
                "timeout 5 findmnt /etc/pve || true",
                "timeout 5 journalctl -u pve-cluster --no-pager | grep -iE 'corosync|cfgtool|wrote new|no change|newer|quorum' | tail -30 || true",
                "timeout 5 journalctl -u pve-cluster --no-pager | tail -60 || true",
                "timeout 5 journalctl -u corosync --no-pager | tail -25 || true",
                "timeout 5 sh -c 'ls -l /etc/corosync/corosync.conf; echo ---; cat /etc/corosync/corosync.conf 2>/dev/null | grep -E \"config_version|nodeid|ring0_addr\"' || true",
                "timeout 5 pvecm status 2>&1 || true",
            ]:
                st, out = m.execute(cmd)
                m.log(f"=== {m.name}: {cmd} (rc={st}) ===")
                m.log(out)

    fingerprint = pve1.succeed("openssl x509 -noout -fingerprint -sha256 -in /etc/pve/local/pve-ssl.pem | cut -d= -f2")

    # Baseline before the join: if the test later dies on a dead backdoor
    # (global timeout), we still have the pre-join cluster state in the log.
    dump_cluster_state()

    # Run the join in a background subshell on pve2, decoupled from the test
    # driver: the join restarts corosync + pmxcfs and reloads pveproxy, which
    # is heavy enough to kill the virtio-console backdoor mid-join. A
    # synchronous execute() would then hang forever (the driver has no read
    # timeout) and we'd hit the global timeout with no diagnostics. Running it
    # in the background means the join always completes on the VM and writes
    # its exit code + output to files we can read with short, bounded commands.
    pve2.succeed("rm -f /tmp/join.rc /tmp/join.log")
    # `rc=0; ... || rc=$?` captures the join's exit code even though execute()
    # runs the command under `set -euo pipefail`: a bare `cmd; echo $?` would
    # abort the subshell on a failed join (errexit) before writing /tmp/join.rc.
    # The trailing `>/dev/null 2>&1` detaches the subshell from the driver's
    # output pipe: without it the subshell inherits fd 1 and holds the pipe open
    # for the whole join, so execute() blocks until the join finishes instead of
    # returning after "launched" (which would also stall the poll heartbeats).
    pve2.succeed(
        "( rc=0; timeout 180 pvesh create /cluster/config/join --hostname 192.168.1.1 "
        f"--fingerprint {fingerprint.strip()} --password mypassword "
        "--force 1 --link0 192.168.1.2 > /tmp/join.log 2>&1 || rc=$?; "
        "echo $rc > /tmp/join.rc ) >/dev/null 2>&1 & echo launched"
    )

    # Poll for the join to finish, heartbeating pve1's membership state while
    # we wait. pve1 is the node that must reload corosync to add pve2, so its
    # timeline is the key diagnostic if the ring never forms. Each poll and
    # heartbeat is a short bounded command, minimising the window in which a
    # transient backdoor I/O error can break the test.
    import time
    deadline = time.time() + 200
    joined = False
    while time.time() < deadline:
        if pve2.succeed("test -f /tmp/join.rc && echo done || echo pending").strip() == "done":
            joined = True
            break
        pve1.log("heartbeat pvecm: " + pve1.succeed("timeout 5 pvecm status 2>&1 | tail -6 || true"))
        time.sleep(10)

    if not joined:
        dump_cluster_state()
        raise Exception("join did not finish within 200s")

    rc = int(pve2.succeed("cat /tmp/join.rc").strip())
    out = pve2.succeed("cat /tmp/join.log")
    if rc != 0:
        dump_cluster_state()
        raise Exception(f"join failed (rc={rc}): {out}")

    # pve2's corosync is still running with its old single-node config:
    # finish_join's `systemctl start corosync` is a no-op when corosync is
    # already active, and pmxcfs only reloads corosync (corosync-cfgtool -R)
    # after CFS changes it processes itself, never at startup. Restart it so
    # the new two-node nodelist takes effect. pve1 needs no restart: its
    # pmxcfs reloads corosync automatically when the nodelist changes in CFS.
    #
    # The restart and the convergence wait are combined into single commands
    # per node: the test driver talks to each VM through a virtio-console
    # backdoor shell, which can die on a transient I/O error under host load;
    # fewer round-trips means a smaller window for that to break the test.
    try:
        pve2.succeed(
            "systemctl restart corosync && timeout 120 sh -c "
            "'until pvecm nodes | grep -qF pve1; do sleep 2; done'"
        )
    except Exception:
        for m in (pve1, pve2):
            for cmd in [
                "findmnt /etc/pve || true",
                "ls -la /etc/pve/ | head -20",
                "journalctl -u pve-cluster --no-pager | grep -iE 'wrote new corosync|cfgtool|critical|error|rename' || true",
                "journalctl -u pve-cluster --no-pager | tail -60",
                "journalctl -u corosync --no-pager | tail -40",
                "pvecm status 2>&1 || true",
            ]:
                status, out = m.execute(cmd)
                m.log(f"=== {m.name}: {cmd} (rc={status}) ===")
                m.log(out)
        raise
    pve1.succeed(
        "timeout 120 sh -c 'until pvecm nodes | grep -qF pve2; do sleep 2; done'"
    )
  '';
}
