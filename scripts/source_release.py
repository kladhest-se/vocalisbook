#!/usr/bin/env python3
# Adapted from ZIFburn/BitSkim release tooling; see retained MIT notices in scripts/.
"""Create a source archive from the explicit release input set."""
import argparse
import gzip
import io
from pathlib import Path
import tarfile
from build_provenance import ROOT, source_files, version


def create(destination, root=ROOT, provenance=None):
    prefix = 'vocalisbook-' + version(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError('Refusing symlinked source archive')
    with destination.open('wb') as output, gzip.GzipFile(fileobj=output, mode='wb', mtime=0, filename='') as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            entries = [(str(p.relative_to(root)), p.read_bytes(), 0o755 if p.stat().st_mode & 0o111 else 0o644)
                       for p in source_files(root)]
            if provenance is not None:
                entries.append(('BUILD-PROVENANCE.json', provenance, 0o644))
            for name, data, mode in entries:
                info = tarfile.TarInfo(prefix + '/' + name)
                info.size, info.mode, info.mtime = len(data), mode, 0
                archive.addfile(info, io.BytesIO(data))
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    print(create(args.output or ROOT / 'outputs/source' / ('vocalisbook-' + version() + '-source.tar.gz')))
