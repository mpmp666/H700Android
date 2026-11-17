#!/usr/bin/env bash
# Small disk experiment for disposable GitHub-hosted Ubuntu 24.04 runners.
# report is read-only; prepare only removes the fixed optional preinstalls below.
set -euo pipefail

case "${1:-}" in
    report|prepare) mode=$1 ;;
    *) printf 'Usage: %s report|prepare\n' "$0" >&2; exit 2 ;;
esac
if (( $# != 1 )); then
    printf 'Usage: %s report|prepare\n' "$0" >&2
    exit 2
fi

python3 -u - "$mode" <<'PY'
import os
import platform
import pwd
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

MODE = sys.argv[1]
GIB = 1024**3
BUDGET = 120 * GIB
# No globs, environment expansion, user paths, package purge or container cleanup.
# Java/JDK, native compilers, build tools, Docker and its storage stay outside this list.
ALLOWLIST = (
    '/usr/local/lib/android',
    '/usr/share/dotnet',
    '/opt/ghc',
    '/usr/local/.ghcup',
    '/opt/hostedtoolcache/CodeQL',
    '/usr/share/swift',
    '/usr/local/share/powershell',
    '/opt/az',
)
KEEP_PATHS = (
    '/usr/lib/jvm', '/usr/bin', '/usr/sbin', '/usr/lib/gcc', '/usr/lib/llvm',
    '/var/lib/docker', '/var/lib/containerd', '/etc/docker',
    '/home', '/root', '/var/log',
)
KEEP_COMMANDS = (
    'java', 'javac', 'bash', 'gcc', 'g++', 'clang', 'make', 'git', 'python3',
    'tar', 'gzip', 'xz', 'curl', 'rsync', 'sudo', 'systemctl', 'docker',
)


def related(left, right):
    """Both ancestors and descendants are protected; /foo != /foobar."""
    return (left == right or left.startswith(right.rstrip('/') + '/')
            or right.startswith(left.rstrip('/') + '/'))


def mount_paths():
    # mountinfo also exposes same-filesystem bind mounts that st_dev cannot detect.
    paths = set()
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        if len(fields) < 10 or ' - ' not in line:
            raise ValueError('Invalid mount table')
        path = re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), fields[4])
        if not path.startswith('/'):
            raise ValueError('Invalid mount path')
        paths.add(path)
    if '/' not in paths:
        raise ValueError('Missing root mount')
    return paths


def directory_state(path):
    # lstat every component, including missing/dangling targets, before realpath.
    current = Path('/')
    for part in Path(path).parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            return 'absent'
        if stat.S_ISLNK(info.st_mode):
            raise ValueError('symlink in target or ancestor')
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError('target or ancestor is not a directory')
    if os.path.realpath(path) != path:
        raise ValueError('target does not resolve to its literal path')
    return 'present'


def protected_paths():
    paths = set(KEEP_PATHS)
    # Protect both the literal environment paths and their canonical destinations.
    # These paths are never removal inputs.
    for name in ('GITHUB_WORKSPACE', 'RUNNER_TEMP', 'HOME'):
        value = os.environ.get(name)
        if value:
            if not os.path.isabs(value):
                raise ValueError('non-absolute protected environment path')
            paths.add(os.path.normpath(value))
            paths.add(os.path.realpath(value))
    paths.add(os.getcwd())
    paths.add(os.path.realpath(os.getcwd()))
    return paths


def validate_target(target, mounts, protected):
    if target not in ALLOWLIST or not target.startswith('/') or os.path.normpath(target) != target:
        raise ValueError('target is not a literal allowed absolute path')
    if any(related(target, path) for path in protected):
        raise ValueError('target overlaps protected tools, workspace, temp or user data')
    # Refuse mounts above, at, or inside a target, including same-device bind mounts.
    if any(path != '/' and related(target, path) for path in mounts):
        raise ValueError('target overlaps a non-root mount')
    state = directory_state(target)
    if state == 'present' and os.stat(target).st_dev != os.stat('/').st_dev:
        raise ValueError('target is on a different filesystem')
    return state


def size_bytes(target):
    try:
        result = subprocess.run(
            ['/usr/bin/du', '-P', '-s', '-x', '-B1', '--', target],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if result.returncode == 0:
            return int(result.stdout.split()[0])
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        pass
    return None


def command_paths():
    return {name: os.path.realpath(path) if (path := shutil.which(name)) else None
            for name in KEEP_COMMANDS}


def disk_sample():
    samples = {}
    for label, path in (
        ('Root filesystem', '/'),
        ('Runner temp', os.environ.get('RUNNER_TEMP') or '/var/tmp'),
        ('Workspace', os.environ.get('GITHUB_WORKSPACE') or os.getcwd()),
    ):
        usage = shutil.disk_usage(path)
        samples[label] = usage
    return samples


def print_disks(samples):
    print('| Location | Total GiB | Free GiB | Free bytes | Meets 120 GiB |')
    print('| --- | ---: | ---: | ---: | --- |')
    for label, usage in samples.items():
        print(f'| {label} | {usage.total / GIB:.2f} | {usage.free / GIB:.2f} | '
              f'{usage.free} | {"yes" if usage.free >= BUDGET else "no"} |')
    print()


def require_hosted_runner():
    required = {
        'GITHUB_ACTIONS': 'true',
        'RUNNER_ENVIRONMENT': 'github-hosted',
        'RUNNER_OS': 'Linux',
        'ImageOS': 'ubuntu24',
    }
    if any(os.environ.get(name) != value for name, value in required.items()):
        raise ValueError('prepare requires GitHub-hosted Ubuntu 24.04 runner markers')
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise ValueError('prepare requires Linux x86_64')
    if os.geteuid() == 0 or pwd.getpwuid(os.getuid()).pw_name != 'runner':
        raise ValueError('prepare requires the unprivileged GitHub runner account')
    for name in ('GITHUB_WORKSPACE', 'RUNNER_TEMP'):
        value = os.environ.get(name, '')
        if not value.startswith('/home/runner/work/') or directory_state(value) != 'present':
            raise ValueError('prepare requires normal non-symlink GitHub runner directories')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line)
    if release.get('ID', '').strip('"') != 'ubuntu' or release.get('VERSION_ID', '').strip('"') != '24.04':
        raise ValueError('prepare requires Ubuntu 24.04')
    result = subprocess.run(['/usr/bin/sudo', '-n', '--', '/usr/bin/true'],
                            capture_output=True, check=False)
    if result.returncode:
        raise ValueError('prepare requires noninteractive runner sudo')


def main():
    print('# H700 runner disk experiment\n')
    print(f'- Mode: {MODE}')
    print('- Planning budget: 120 GiB free at runner temp; this is an estimate.')
    print('- Only fixed optional system preinstalls are eligible; no package or container cleanup.')
    print('- Directory sizes are measured allocated bytes, not a promise of recovered space.\n')
    if MODE == 'prepare':
        # No privileged command or deletion is reached before this environment guard.
        require_hosted_runner()
    mounts = mount_paths()
    protected = protected_paths()
    before_commands = command_paths()
    # An executable reached through an unexpected symlink must also remain protected.
    protected.update(path for path in before_commands.values() if path)
    before = disk_sample()
    print('## Before\n')
    print_disks(before)
    print('## Fixed removal plan\n')
    print('| Literal allowed path | State | Allocated GiB |')
    print('| --- | --- | ---: |')
    plan = []
    problems = False
    for target in ALLOWLIST:
        try:
            state = validate_target(target, mounts, protected)
            size = size_bytes(target) if state == 'present' else 0
            plan.append((target, state))
        except ValueError as error:
            state = f'REFUSED: {error}'
            size = None
            problems = True
        size_text = f'{size / GIB:.2f}' if size is not None else 'unknown'
        print(f'| `{target}` | {state} | {size_text} |')
    print()
    if MODE == 'prepare' and problems:
        raise ValueError('unsafe target in plan; no targets were deleted')

    if MODE == 'prepare':
        print('## Preparation\n')
        for target, state in plan:
            # Check the exact literal path and current mount table again immediately
            # before every rm. Never follow symlink targets or cross filesystems.
            current_state = validate_target(target, mount_paths(), protected_paths() | protected)
            if current_state == 'absent':
                print(f'- Absent, skipped: `{target}`')
                continue
            if state != 'present':
                raise ValueError('target appeared after planning; refusing deletion')
            result = subprocess.run(
                ['/usr/bin/sudo', '-n', '--', '/usr/bin/rm', '--recursive', '--force',
                 '--one-file-system', '--preserve-root=all', '--', target],
                capture_output=True, check=False,
            )
            if result.returncode:
                raise ValueError('fixed-target removal failed; see completed entries above')
            if os.path.lexists(target):
                raise ValueError('fixed target still exists after removal')
            print(f'- Removed: `{target}`')
        print()

    after = disk_sample()
    print('## After' + (' (report only; no changes made)' if MODE == 'report' else '') + '\n')
    print_disks(after)
    delta = after['Runner temp'].free - before['Runner temp'].free
    print(f'- Runner temp free-space change: {delta / GIB:+.2f} GiB ({delta:+d} bytes).\n')
    print('## Retained command checks\n')
    print('| Command | Before | After |')
    print('| --- | --- | --- |')
    after_commands = command_paths()
    changed = False
    for name, old in before_commands.items():
        new = after_commands[name]
        changed = changed or (old is not None and old != new)
        print(f'| `{name}` | {"available" if old else "not installed"} | '
              f'{"available (same target)" if old and new == old else "available" if new else "not installed"} |')
    print()
    if changed:
        raise ValueError('a previously available retained command changed or disappeared')
    enough = after['Runner temp'].free >= BUDGET
    print(f'- 120 GiB at runner temp: **{"met" if enough else "not met"}**.')
    print('- Only a real cloud run establishes available disk on that runner image; '
          'the full Android build and its peak storage remain unverified.')
    if MODE == 'prepare' and not enough:
        print('::warning::Runner preparation completed, but runner temp is still below 120 GiB.')
    return 0


try:
    sys.exit(main())
except (OSError, ValueError, subprocess.SubprocessError) as error:
    # Do not dump subprocess output, file contents, environment values or raw logs.
    message = str(error) if isinstance(error, ValueError) else type(error).__name__
    print(f'\n**Experiment stopped:** {message}.')
    print(f'::error::H700 runner space experiment stopped: {message}')
    sys.exit(2)
PY
