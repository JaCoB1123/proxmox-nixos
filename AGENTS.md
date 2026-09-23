# Agent Guide

## Repository purpose

This flake ports Proxmox VE and related components to NixOS. It has three connected layers:

- `pkgs/` packages upstream Proxmox, LINSTOR, and supporting software as Nix derivations. `pkgs/default.nix` is the package registry and supplies a customized `perl5` and `libxcrypt` to all local packages.
- `modules/` exposes the NixOS modules exported by the flake: `proxmox-ve`, `proxmox-backup`, and `declarative-vms`. The VE module composes service-specific files under `modules/proxmox-ve/`.
- `tests/` contains NixOS VM tests. They import the flake's modules through `extraBaseModules`, so tests exercise the exported module integration, not only individual derivations.

`flake.nix` is the integration point: it imports `pkgs/` as both the overlay and package set, exposes `modules/` as `nixosModules`, and exposes packages plus enabled NixOS tests as `checks` on `x86_64-linux`. Other systems export packages but no checks. `default.nix` preserves non-flake compatibility through `flake-compat`.

## Essential commands

Run commands from the repository root.

| Purpose | Command |
| --- | --- |
| Evaluate all flake outputs without building | `nix flake check --no-build` |
| Build one exported package | `nix build -L .#pve-manager` |
| Build the full Proxmox VE bundle | `nix build -L .#proxmox-ve` |
| Run one NixOS VM test | `nix build -L .#checks.x86_64-linux.test-pve-basic` |
| Run all enabled checks on the supported platform | `nix build -L '.#checks.x86_64-linux'` |
| Run `nixmoxer` for a configured host | `nix run .#nixmoxer -- [--flake] [--node NODE] HOST` |

The flake declares the project's binary cache in `flake.nix`; retain it when using Nix commands because several package builds are expensive. CI uses `nix build -L --print-out-paths` against an evaluated Hestia matrix, rather than a separate formatter or linter.

## Working on packages

- Add a package to `pkgs/default.nix` with `callPackage`; this makes it available to the overlay, `packages`, and (on `x86_64-linux`) `checks`.
- Package definitions normally pin upstream source with `fetchgit` or another fixed-output fetcher, declare `pname` and `version`, and use `postPatch`, `makeFlags`, `postInstall`, and `postFixup` to adapt Debian-oriented Proxmox builds to immutable Nix store paths.
- Preserve dependency wiring deliberately. Many Proxmox packages are converted with `perl5.pkgs.toPerlModule`, receive a custom `perlEnv`, rewrite hard-coded `/usr` paths, and wrap executables with `PATH` and `PERL5LIB`. A dependency missing from a wrapper can fail only at service runtime.
- Keep source pins, hashes, local patches, and package version together in the owning package directory. Several packages expose `passthru.updateScript = pve-update-script { };` for automated updates.
- The shared `perl5` override is functional: it restores `sha256crypt` in `libxcrypt` and patches XML::Twig to avoid stderr output that breaks Proxmox storage-migration readiness handshakes. Do not bypass it by importing an unrelated Perl package set.

## Working on modules

- Follow the existing NixOS-module shape: bind `cfg` to the relevant option subtree, declare options at the public path, and guard configuration with `mkIf cfg.enable`.
- `modules/proxmox-ve/default.nix` owns top-level options and imports feature modules. Service units belong in the focused file, with explicit systemd ordering and runtime tools in `path` where needed.
- The VE package is a `buildEnv` aggregation of Proxmox components. Modules install it as `cfg.package`; package changes therefore affect the service modules' executable paths.
- `virtualisation.proxmox` is a bootstrap interface. `nixmoxer` creates and initially configures a VM through the Proxmox API, but later option changes do not reconcile an existing VM. Likewise, entries in `services.proxmox-ve.vms` only create previously uninitialized VMs.
- The primary supported deployment platform is `x86_64-linux`, even though the flake exports package outputs for Linux and Darwin systems. Do not treat a successful evaluation on another platform as support.

## Tests and validation

Tests are `pkgs.testers.runNixOSTest` definitions. Add a test file under `tests/`, then register it in `tests/default.nix`; an unregistered test is not exposed by the flake or CI. Test scripts use the NixOS test Python API (`machine.start()`, `wait_for_unit`, `succeed`) and should wait for the relevant service before asserting behavior.

`test-pve-ceph` is present but commented out in `tests/default.nix`, so it is intentionally excluded from the enabled check set. Target the smallest affected package or VM test first; run the full `x86_64-linux` check set when changing shared package wiring, module integration, or test registration.

## Updates and CI

Automated package updates use `tasks/update.nix` and `tasks/update.py`. The documented commands are:

```bash
# Update all eligible packages and commit generated changes
nix-shell tasks/update.nix --arg predicate '_: _: true' --argstr commit true

# Update only Proxmox packages
nix-shell tasks/update.nix --arg predicate '_: pkg: builtins.match ".*proxmox.*" pkg.src.url == []'

# Update only Perl packages
nix-shell tasks/update.nix --arg predicate '_: pkg: builtins.match ".*cpan.*" pkg.src.url == []'
```

The updater can create temporary git worktrees and, with `commit true`, commits and cherry-picks update results. Treat it as a repository-mutating maintenance command, not a read-only version check.

GitHub Actions uses Hestia to evaluate only the affected installables, builds those installables with KVM enabled for VM tests, and pushes artifacts to the binary cache only for pushes to `main` when cache credentials are available.
