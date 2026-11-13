# Adapted from ZIFburn/BitSkim release tooling; see retained MIT notices in scripts/.
"""Shared settings, credential and source-push helpers adapted from BitSkim.

See LICENSE-BitSkim for the upstream MIT license.
"""
import json
import os
from pathlib import Path
import re
import subprocess

from build_provenance import ROOT, commit, require, run, source_files


def default_config_path():
    return Path(os.environ.get('VOCALISBOOK_RELEASE_CONFIG',
                str(Path.home() / 'Development/tools/git-release/projects/vocalisbook.json'))).expanduser()


def validate_credentials(settings):
    require(isinstance(settings, dict) and not set(settings) - {'github', 'gitlab'}, 'Invalid credential services')
    for spec in settings.values():
        require(isinstance(spec, dict), 'Credential settings must be objects')
        provider = spec.get('provider', 'env')
        allowed = {'provider', 'variable'} if provider == 'env' else {'provider', 'reference', 'vault', 'item', 'field', 'account'}
        require(provider in ('env', '1password') and not set(spec) - allowed, 'Invalid credential provider/settings')
        require(all(isinstance(v, str) and not any(ord(c) < 32 for c in v) for v in spec.values()),
                'Invalid credential reference')
        if provider == 'env':
            require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', spec.get('variable', 'TOKEN')), 'Invalid token variable name')
        elif spec.get('reference'):
            require(spec['reference'].startswith('op://') and len(spec['reference'].split('/')) >= 5,
                    'Invalid 1Password reference')
        else:
            require(all(spec.get(key) for key in ('vault', 'item', 'field')), 'Configure vault/item/field or an exact secret reference')


def credential(service, config):
    settings = config.get('credentials', {})
    validate_credentials(settings)
    spec = settings.get(service, {})
    if spec.get('provider', 'env') == 'env':
        token = os.environ.get(spec.get('variable', service.upper() + '_TOKEN'), '')
    else:
        reference = spec.get('reference')
        if reference:
            command = ['op', 'read', '--no-newline', reference]
        else:
            command = ['op', 'item', 'get', spec['item'], '--vault', spec['vault'], '--fields',
                       'label=' + spec['field'], '--format', 'json', '--reveal']
        if spec.get('account'):
            command += ['--account', spec['account']]
        try:
            result = subprocess.run(command, capture_output=True, text=True)
        except OSError:
            raise ValueError('1Password CLI is unavailable; no secret output displayed') from None
        require(result.returncode == 0, '1Password lookup failed or was cancelled; no secret output displayed')
        if reference:
            token = result.stdout
        else:
            try:
                data = json.loads(result.stdout)
                fields = data if isinstance(data, list) else data.get('fields', [data])
                matches = [field for field in fields if field.get('label') == spec['field'] and field.get('value')]
                require(len(matches) == 1, 'Ambiguous field')
                token = matches[0]['value']
            except (ValueError, KeyError, TypeError, AttributeError):
                raise ValueError('1Password field missing or ambiguous; use an exact reference') from None
    require(isinstance(token, str) and token.strip() and not token.startswith('op://')
            and not any(ord(c) < 32 for c in token.strip()),
            'Missing/unresolved token for ' + service + '; configure 1Password or ' + service.upper() + '_TOKEN')
    return token.strip()


def release_tag(tag=None, version='0.1'):
    tag = 'v' + version if tag is None else tag
    require(tag and not tag.startswith('-'), 'Invalid release tag')
    checked = subprocess.run(['git', 'check-ref-format', 'refs/tags/' + tag], capture_output=True)
    require(checked.returncode == 0, 'Invalid release tag')
    return tag


def initialize_source(config, services, destination, root=ROOT, commit_message=None):
    detected = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=root, capture_output=True, text=True)
    if detected.returncode == 0:
        require(Path(detected.stdout.strip()).samefile(root), 'Refusing to initialize inside another checkout')
        if subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=root, capture_output=True).returncode == 0:
            return
    else:
        require(not (root / '.git').exists() and not (root / '.git').is_symlink(), 'Invalid existing Git metadata')
    require((root / '.gitignore').is_file(), 'Review .gitignore before initializing source')
    remotes = {s: destination(config, s) for s in services}
    for url in remotes.values():
        require(not run(['git', 'ls-remote', '--refs', url], root, True),
                'Remote already has history; clone it and preserve its commits instead')
    for identity in ('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT'):
        require(subprocess.run(['git', 'var', identity], cwd=root, capture_output=True).returncode == 0,
                'Configure Git user.name and user.email before initializing')
    branch = config.get('source_branch') or 'main'
    run(['git', 'check-ref-format', '--branch', branch], root, True)
    if detected.returncode:
        run(['git', 'init', '--initial-branch', branch], root, True)
    # Stage only reviewed release inputs, not unrelated local files.
    inputs = [str(p.relative_to(root)) for p in source_files(root)]
    existing = run(['git', 'ls-files', '-z'], root, True).split('\0')
    require(not set(filter(None, existing)) - set(inputs), 'Unrelated files already staged in initial repository')
    run(['git', 'add', '--', *inputs], root)
    run(['git', 'commit', '-m', commit_message or 'VocalisBook source release'], root, True)
    print('Created initial local commit. No source upload performed by initialization.')


def push_source(config, services, destination, confirmed=False, dry_run=False, root=ROOT,
                initialize=False, commit_message=None):
    require(dry_run or confirmed, 'Use --dry-run first, then --confirm-push to upload source')
    require(services and len(set(services)) == len(services) and not set(services) - {'github', 'gitlab'},
            'Source push supports distinct github/gitlab destinations')
    if initialize:
        initialize_source(config, services, destination, root, commit_message)
    revision = commit(root, clean=True)
    branch = run(['git', 'symbolic-ref', '--quiet', '--short', 'HEAD'], root, True)
    target = config.get('source_branch') or branch
    run(['git', 'check-ref-format', '--branch', target], root, True)
    refspec = 'refs/heads/' + branch + ':refs/heads/' + target
    remotes = {s: destination(config, s) for s in services}
    for service, url in remotes.items():
        print('Checking source push: ' + service + ' (' + branch + ' -> ' + target + ')')
        run(['git', 'push', '--dry-run', '--no-follow-tags', url, refspec], root)
    if dry_run:
        print('Source preflight passed; nothing uploaded.')
        return
    for service, url in remotes.items():
        require(commit(root, clean=True) == revision, 'Source changed during source push')
        run(['git', 'push', '--no-follow-tags', url, refspec], root)
        current = run(['git', 'ls-remote', '--heads', url, 'refs/heads/' + target], root, True)
        require(current and current.split()[0] == revision, 'Remote source branch verification failed')
        print(service + ': source branch verified')
