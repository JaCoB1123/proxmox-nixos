{
  lib,
  stdenv,
  fetchgit,
  perl5,
  dtach,
  lxc,
  openssh,
  tzdata,
  pve-update-script,
}:

let
  perlDeps = [ ];
  perlEnv = perl5.withPackages (_: perlDeps);
in

perl5.pkgs.toPerlModule (
  stdenv.mkDerivation rec {
    pname = "pve-container";
    version = "6.1.13";

    src = fetchgit {
      url = "git://git.proxmox.com/git/${pname}.git";
      rev = "c8132559faedb76a56498d411bf3e024c1ff07e7";
      hash = "sha256-hYKInUR414O6tMjfboiH9iGelZA/zmjzwf94k8rvBus=";
    };

    sourceRoot = "${src.name}/src";

    postPatch = ''
      sed -i Makefile \
        -e "s/pct.1 pct.conf.5 pct.bash-completion pct.zsh-completion //" \
        -e "s,/usr/share/lxc,$NIX_BUILD_TOP/lxc," \
        -e "/pve-doc-generator/d" \
        -e "/PVE_GENERATING_DOCS/d" \
        -e "/SERVICEDIR/d" \
        -e "/BASHCOMPLDIR/d" \
        -e "/ZSHCOMPLDIR/d" \
        -e "/MAN1DIR/d" \
        -e "/MAN5DIR/d"
    '';

    buildInputs = [ perlEnv ];
    propagatedBuildInputs = perlDeps;
    dontPatchShebangs = true;

    postConfigure = ''
      cp -r ${lxc}/share/lxc $NIX_BUILD_TOP/
      chmod -R +w $NIX_BUILD_TOP/lxc
    '';

    postInstall = ''
      # PVE references lxc's config files (common.seccomp, common.conf,
      # userns.conf) and hooks via paths that point at this package's own
      # store path (see postFixup), but on a normal system those files are
      # provided by the lxc package in a shared /usr/share/lxc directory.
      # Install them here so this package is self-contained.
      cp -r $NIX_BUILD_TOP/lxc/config/* $out/share/lxc/config/
      cp -r $NIX_BUILD_TOP/lxc/hooks/* $out/share/lxc/hooks/
      # nixpkgs' lxc derivation rewrites internal references to the system
      # profile, which does not contain lxc; repoint them at our own copy.
      find $out/share/lxc -type f -exec sed -i "s|/run/current-system/sw/share|$out/share|g" {} +
    '';

    makeFlags = [
      "DESTDIR=$(out)"
      "PREFIX=$(out)"
      "SBINDIR=$(out)/.bin"
      "PERLDIR=$(out)/${perl5.libPrefix}/${perl5.version}"
    ];

    postFixup = ''
      find $out -type f | xargs sed -i \
        -e "s|/usr/bin/dtach|${dtach}/bin/dtach|" \
        -e "s|/usr/bin/ssh|${openssh}/bin/ssh|" \
        -e "s|/bin/true|true|" \
        -e "s|/usr/bin/vncterm||" \
        -e "s|/usr/bin/termproxy||" \
        -e "s|/usr/bin/lxc|${lxc}/bin/lxc|" \
        -e "s|/usr/share/lxc|$out/share/lxc|" \
        -e "s|/usr/share/zoneinfo|${tzdata}/share/zoneinfo|"
    '';

    passthru.updateScript = pve-update-script { };

    meta = with lib; {
      description = "Proxmox VE container manager & runtime";
      homepage = "https://git.proxmox.com/?p=pve-container.git";
      license = licenses.agpl3Plus;
      maintainers = with maintainers; [
        camillemndn
        julienmalka
      ];
      platforms = platforms.linux;
    };
  }
)
