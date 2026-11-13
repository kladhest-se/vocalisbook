"""Package the PHP website independently of a repository release."""
import argparse
from pathlib import Path
from build_provenance import ROOT
from release import create_website

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/vocalisbook-website.tar.gz')
    args = parser.parse_args()
    create_website(args.output)
    print(args.output)
