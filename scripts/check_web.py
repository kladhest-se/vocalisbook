"""Render both PHP routes and check local assets without external requests."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            if attrs['id'] in self.ids:
                raise ValueError('Duplicate HTML id: ' + attrs['id'])
            self.ids.add(attrs['id'])
        if tag == 'img' and not attrs.get('alt'):
            raise ValueError('Image has no alternative text')
        self.links.extend(attrs[k] for k in ('src', 'href') if k in attrs)

def check(root=ROOT):
    web = root / 'public-web'
    php = os.environ.get('PHP', 'php')
    if not shutil.which(php):
        raise ValueError('PHP is required for website checks; set PHP to its executable path.')
    for path in sorted(web.glob('*.php')):
        subprocess.run([php, '-l', str(path)], check=True, capture_output=True, text=True)
    for privacy in (False, True):
        snippet = "if ($argv[2] === 'privacy') { $_GET['privacy'] = '1'; } include $argv[1];"
        rendered = subprocess.run([php, '-d', 'display_errors=stderr', '-d', 'error_reporting=-1',
                                   '-r', snippet, str(web / 'index.php'), 'privacy' if privacy else 'home'],
                                  check=True, capture_output=True, text=True)
        if rendered.stderr or '<?php' in rendered.stdout:
            raise ValueError('PHP route failed to render cleanly')
        parser = Page(); parser.feed(rendered.stdout)
        for link in parser.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                if url.scheme not in ('https', 'mailto'):
                    raise ValueError('Unexpected link scheme: ' + link)
                continue
            if url.path:
                target = (web / unquote(url.path)).resolve()
                if not target.is_relative_to(web.resolve()) or not (target.is_file() or target == web.resolve()):
                    raise ValueError('Missing or unsafe local website link: ' + link)
            if url.fragment and not url.path and unquote(url.fragment) not in parser.ids:
                raise ValueError('Missing local section: ' + link)
    print('Both PHP routes, local links and image alternative text passed.')

if __name__ == '__main__':
    check()
