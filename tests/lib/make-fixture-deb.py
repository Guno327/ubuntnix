#!/usr/bin/env python3
"""tests/lib/make-fixture-deb.py — build a minimal, real .deb archive from a
declarative JSON entry list, WITHOUT needing root or fakeroot (GitHub issue
#10 PR #36's tests/unit/080-compose-ownership-scan.sh: it needs a real .deb
whose data.tar embeds non-root ownership, e.g. root:shadow, to exercise
bin/ubx-scan-deb-ownership against actual dpkg-deb/tar output rather than a
hand-typed fixture of what that output is assumed to look like).

A .deb is a plain `ar` archive (magic "!<arch>\\n" + fixed 60-byte member
headers) containing debian-binary, control.tar.gz, and data.tar.gz.
`dpkg-deb -b` cannot build a non-root-owned tree without root/fakeroot (it
tars the SOURCE DIRECTORY's own on-disk ownership) -- but Python's
`tarfile` module can write ARBITRARY uid/gid/uname/gname metadata into a
tar member directly, no chown(2) or privilege of any kind involved (it is
pure bytes on the wire). This script uses exactly that to construct a
realistic fixture, then wraps it in the `ar` container by hand (also pure
byte-writing, no external `ar` tool needed).

Usage: make-fixture-deb.py OUT.deb ENTRIES.json
ENTRIES.json: a JSON list of {"name": "./usr/sbin/x", "type": "file"|"dir"|
"symlink"|"hardlink"|"chardev", "data": "...", "mode": 420, "uid": 0,
"gid": 42, "uname": "root", "gname": "shadow", "linkname": "..."} objects,
in the SAME shape data.tar entries take (see this project's own use in
tests/unit/080-compose-ownership-scan.sh for concrete examples).
"""
import gzip
import io
import json
import sys
import tarfile

_TYPES = {
    "file": None,  # regular, the tarfile default
    "dir": tarfile.DIRTYPE,
    "symlink": tarfile.SYMTYPE,
    "hardlink": tarfile.LNKTYPE,
    "chardev": tarfile.CHRTYPE,
}


def make_tar_gz(entries):
    buf = io.BytesIO()
    # mtime=0 in both the gzip wrapper and every tar member: irrelevant to
    # what this script tests (ownership/mode parsing), but pinning it
    # avoids any accidental timestamp-dependent byte-diff surprise if a
    # test ever compares two builds of the same fixture.
    gz = gzip.GzipFile(fileobj=buf, mode="wb", mtime=0)
    tf = tarfile.TarFile(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT)
    for e in entries:
        ti = tarfile.TarInfo(name=e["name"])
        ti.mode = e.get("mode", 0o644)
        ti.uid = e.get("uid", 0)
        ti.gid = e.get("gid", 0)
        ti.uname = e.get("uname", "root")
        ti.gname = e.get("gname", "root")
        ti.mtime = 0
        kind = _TYPES[e.get("type", "file")]
        if kind == tarfile.DIRTYPE:
            ti.type = kind
            tf.addfile(ti)
        elif kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            ti.type = kind
            ti.linkname = e["linkname"]
            tf.addfile(ti)
        elif kind == tarfile.CHRTYPE:
            ti.type = kind
            ti.devmajor = e.get("devmajor", 1)
            ti.devminor = e.get("devminor", 3)
            tf.addfile(ti)
        else:
            data = e.get("data", "").encode("utf-8")
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
    tf.close()
    gz.close()
    return buf.getvalue()


def ar_member(name, data):
    # ar(5)'s fixed 60-byte member header: name(16) mtime(12) uid(6) gid(6)
    # mode(8) size(10) end("`\n"). mtime/uid/gid/mode are irrelevant here
    # (dpkg-deb reads the debian-binary/control.tar/data.tar CONTENT, never
    # this outer ar envelope's own metadata) -- zeroed for determinism.
    header = "%-16s%-12s%-6s%-6s%-8s%-10s`\n" % (name, "0", "0", "0", "100644", str(len(data)))
    body = data
    if len(body) % 2 == 1:
        body += b"\n"  # ar pads member data to an even length
    return header.encode("ascii") + body


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} OUT.deb ENTRIES.json")
    out_path, entries_path = sys.argv[1], sys.argv[2]

    with open(entries_path) as f:
        entries = json.load(f)

    control_txt = (
        "Package: fixture\n"
        "Version: 1.0\n"
        "Architecture: amd64\n"
        "Maintainer: ubuntnix tests <noreply@example.com>\n"
        "Installed-Size: 1\n"
        "Section: test\n"
        "Priority: optional\n"
        "Description: ubx-scan-deb-ownership test fixture\n"
    )
    control_tar = make_tar_gz([{"name": "./control", "data": control_txt}])
    data_tar = make_tar_gz(entries)

    out = b"!<arch>\n"
    out += ar_member("debian-binary", b"2.0\n")
    out += ar_member("control.tar.gz", control_tar)
    out += ar_member("data.tar.gz", data_tar)

    with open(out_path, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main()
