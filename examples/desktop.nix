# examples/desktop.nix — the **desktop parity example config** (SPEC.md
# §10: "The parity example configs double as ubuntnix's reference
# configurations in the repo and CI"; §11 M6 exit criterion; GitHub issue
# #107).
#
# Direct sibling of examples/server.nix — read that file's own header
# first (this file mirrors its reasoning verbatim, "Desktop" in place of
# "Server"): a PLAIN attrset, not a flake-parts module, in exactly SPEC.md
# §6's own worked-example shape, wiring the landed M5 base modules
# (networking, fileSystems+swap, i18n/console/time, users) together with
# `profiles.desktop.enable = true;`.
#
# `nix/profiles.nix`'s own `perSystem` block (`packages.desktop-parity-
# image`) is the ONLY consumer of this file inside the flake today — it
# imports this exact attrset, runs each field through the already-landed
# base module `render`/`validate` functions, and bakes the result into a
# bootable disk image (a BUILD-TIME parity/proof target; the live QEMU
# graphical-boot e2e is a separate issue, #108 — see nix/profiles.nix's own
# header, "Desktop", for that scope boundary).
#
# See examples/server.nix's own header, "Why `nofail`/short device
# timeouts on fileSystems/swapDevices", for why the declared `/data` mount
# and swap device below use those options — identical reasoning applies
# here (no second/third disk attached to the throwaway build/boot target).
{
  networking = {
    hostname = "ubuntnix-desktop";
    hosts = { };
    interfaces.eth0 = {
      dhcp4 = true;
    };
  };

  fileSystems = {
    "/data" = {
      device = "/dev/disk/by-uuid/33333333-3333-3333-3333-333333333333";
      fsType = "ext4";
      options = "defaults,nofail,x-systemd.device-timeout=1";
    };
  };

  swapDevices = [
    {
      device = "/dev/disk/by-uuid/44444444-4444-4444-4444-444444444444";
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
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-desktop"
      ];
    };
  };

  groups = { };

  profiles.desktop.enable = true;
}
