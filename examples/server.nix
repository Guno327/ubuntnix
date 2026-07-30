# examples/server.nix — the **server parity example config** (SPEC.md §10:
# "The parity example configs double as ubuntnix's reference configurations
# in the repo and CI"; §11 M5 exit criterion; GitHub issue #99).
#
# A PLAIN attrset, not a flake-parts module — deliberately the same shape
# SPEC.md §6's own worked examples use verbatim (`networking = { ... };`,
# `fileSystems."/data" = { ... };`, `i18n.locale = "..."`, `profiles.server.
# enable = true;`), because this file's whole point is to BE that worked
# example, made real: every showcase-module/primitive declaration a real
# `/flake` machine config would write for a server install (SPEC.md §10's
# installer step 2: "writes the initial generation (built from the parity
# example config matching the user's choices)").
#
# `nix/profiles.nix`'s own `perSystem` block (`packages.server-parity-
# image`) is the ONLY consumer of this file inside the flake today — it
# imports this exact attrset, runs each field through the already-landed
# base module `render`/`validate` functions this file's siblings are
# named after (nix/networking.nix, nix/filesystems.nix, nix/localization.nix,
# nix/users.nix), and bakes the result into a bootable QEMU disk image
# (tests/e2e/050-qemu-server-parity-e2e.sh's own subject). Nothing here
# talks to those modules directly — this file only ever holds plain,
# already-documented declaration shapes, exactly like a real `/flake`
# machine config would.
#
# -- Why `nofail`/short device timeouts on fileSystems/swapDevices ---------
#
# The declared `/data` mount and swap device below point at UUIDs that do
# not exist on the throwaway QEMU disk this config is actually booted on
# (there is no second/third disk attached — see the e2e test's own header
# for why a real backing device is out of scope for a package-set/wiring
# proof). A bare fstab entry for a missing device would otherwise block
# `local-fs.target` for systemd's full default device-timeout before
# continuing — `nofail` (skip the unit's ordering dependency on
# `local-fs.target` entirely — systemd.mount(5)/fstab(5)) plus a 1-second
# `x-systemd.device-timeout` (belt-and-suspenders, in case a future systemd
# default ever changes `nofail`'s own no-wait behavior) keeps this config
# realistic-shaped (a real server commonly has an optional data/swap
# volume that isn't always present, e.g. a cloud instance's ephemeral disk)
# without risking the e2e boot hanging on it.
{
  networking = {
    hostname = "ubuntnix-server";
    hosts = { };
    interfaces.eth0 = {
      dhcp4 = true;
    };
  };

  fileSystems = {
    "/data" = {
      device = "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111";
      fsType = "ext4";
      options = "defaults,nofail,x-systemd.device-timeout=1";
    };
  };

  swapDevices = [
    {
      device = "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222";
      options = "nofail,x-systemd.device-timeout=1";
    }
  ];

  i18n = {
    locale = "en_US.UTF-8";
  };

  console = {
    keymap = "us";
  };

  time = {
    timeZone = "UTC";
  };

  users = {
    gunnar = {
      groups = [ "sudo" ];
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-server"
      ];
    };
  };

  groups = { };

  profiles.server.enable = true;
}
