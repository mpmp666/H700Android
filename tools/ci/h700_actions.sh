#!/usr/bin/env bash
# GitHub Actions adapter for the documented public build. Never accesses devices.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
cd "$repo"

report() {
    python3 - <<'PY'
import os
import platform
import shutil
from pathlib import Path

root = Path(os.environ.get('RUNNER_TEMP', '/var/tmp'))
free = shutil.disk_usage(root).free / 1024**3
lines = [
    '## H700 build readiness',
    '',
    f'- Platform: {platform.system()} {platform.machine()}',
    f'- Logical CPUs: {os.cpu_count()}',
    f'- Free space at runner temp: {free:.1f} GiB',
    '- Full build planning budget: 120 GiB free (estimate, not a proven upper bound).',
]
for name in ('H700_ANDROID_URL', 'H700_IMAGE_URL'):
    lines.append(f'- {name}: ' + ('configured' if os.environ.get(name) else 'missing'))
lines += [
    '',
    'The full build requires the exact android.tar.gz and 0.0.1 reference image from external-inputs.json.',
    'Baidu share landing pages are not direct file download URLs.',
    'Standard hosted runners are not guaranteed to have enough disk space or enough execution time.',
    'Navigation checks compile host Java code; they do not produce an Android image or prove RG35XX Pro compatibility.',
]
text = '\n'.join(lines) + '\n'
print(text)
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
        stream.write(text)
PY
}

preflight() {
    report
    python3 - <<'PY'
import os
import platform
import shutil
import sys
from pathlib import Path
from urllib.parse import urlsplit

problems = []
for name in ('H700_ANDROID_URL', 'H700_IMAGE_URL'):
    value = os.environ.get(name, '')
    parsed = urlsplit(value)
    if not value:
        problems.append(f'Missing repository Actions secret: {name}')
    elif parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        problems.append(f'{name} must be an HTTPS file URL without URL userinfo')
    elif parsed.hostname.lower() in ('pan.baidu.com', 'yun.baidu.com'):
        problems.append(f'{name} is a Baidu share page; provide a usable direct file source')
root = Path(os.environ.get('RUNNER_TEMP', '/var/tmp'))
if shutil.disk_usage(root).free < 120 * 1024**3:
    problems.append('Less than the 120 GiB planning budget is free. Use a Linux x86_64 runner with more storage.')
if platform.system() != 'Linux' or platform.machine() != 'x86_64':
    problems.append('The public Android toolchain requires Linux x86_64')
if not Path('/run/systemd/system').is_dir() or not Path('/sys/fs/cgroup/cgroup.controllers').is_file():
    problems.append('The resource wrapper requires systemd and cgroup v2')
if not {0, 1}.issubset(os.sched_getaffinity(0)):
    problems.append('CPUs 0 and 1 must both be available to retain the project affinity constraint')
if problems:
    for item in problems:
        print('::error::' + item)
    sys.exit(2)
PY
    work=$(mktemp -d "${RUNNER_TEMP:?}/h700-build.XXXXXX")
    printf 'H700_WORK=%s\n' "$work" >> "${GITHUB_ENV:?}"
    printf 'WORK=%s\n' "$work"
}

# Run each download in a child with only its own URL in the environment.
# Do not print signed URLs or put them in process arguments.
download_one() {
    H700_DOWNLOAD_KEY="$1" H700_DOWNLOAD_OUTPUT="$2" python3 - <<'PY'
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

key = os.environ['H700_DOWNLOAD_KEY']
url = os.environ[key]
path = Path(os.environ['H700_DOWNLOAD_OUTPUT'])
specs = json.loads(Path('build-support/public/external-inputs.json').read_text())
spec = next(x for x in specs['source_archives'] if x['name'] == 'android.tar.gz') if key == 'H700_ANDROID_URL' else specs['reference_image']
if path.exists():
    raise SystemExit('Refuse overwriting an existing input')

class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, target):
        if urlsplit(target).scheme != 'https':
            raise ValueError('Non-HTTPS redirect refused')
        return super().redirect_request(request, fp, code, message, headers, target)

opener = urllib.request.build_opener(HTTPSRedirect)
count = 0
sha = hashlib.sha256()
try:
    request = urllib.request.Request(url, headers={'User-Agent': 'H700-community-build/1.0'})
    with opener.open(request, timeout=120) as response, path.open('xb') as stream:
        if response.status != 200:
            raise ValueError('Download did not return HTTP 200')
        while block := response.read(4 * 1024**2):
            count += len(block)
            if count > spec['bytes']:
                raise ValueError('Download exceeds locked file size')
            sha.update(block)
            stream.write(block)
    if count != spec['bytes'] or sha.hexdigest() != spec['sha256']:
        raise ValueError('Downloaded input does not match locked size/SHA256')
except Exception as error:
    # Exception messages can include signed URLs, so report only safe details.
    status = error.code if isinstance(error, urllib.error.HTTPError) else None
    print(f'::error::{key} download/identity failed: {type(error).__name__}; HTTP status={status}; received bytes={count}', file=sys.stderr)
    raise SystemExit(2)
print(f'VERIFIED {path.name}: {count} bytes, SHA256 {sha.hexdigest()}')
PY
}

case "${1:-}" in
    report) report ;;
    preflight) preflight ;;
    download)
        mkdir "${H700_WORK:?}/downloads"
        download_one H700_ANDROID_URL "$H700_WORK/downloads/android.tar.gz"
        download_one H700_IMAGE_URL "$H700_WORK/downloads/ROC_OS_ARM64_ver0.0.1.img.gz"
        ;;
    prepare)
        : "${H700_WORK:?}"
        bash "$repo/tools/public_build/run-limited.sh" \
            tar --no-same-owner -xzf "$H700_WORK/downloads/android.tar.gz" -C "$H700_WORK"
        test -f "$H700_WORK/android/build/envsetup.sh"
        bash "$repo/tools/public_build/run-limited.sh" \
            python3 -B "$repo/tools/public_build/extract.py" \
            --image "$H700_WORK/downloads/ROC_OS_ARM64_ver0.0.1.img.gz" \
            --output "$H700_WORK/image-inputs"
        # New throwaway identity per attempt. Never uploaded as an artifact/cache.
        python3 -B "$repo/tools/public_build/keys.py" --output "$H700_WORK/keys"
        bash "$repo/tools/public_build/run-limited.sh" \
            python3 -B "$repo/tools/public_build/prepare.py" \
            --source "$H700_WORK/android" --inputs "$H700_WORK/image-inputs" \
            --keys "$H700_WORK/keys" --apply
        ;;
    *) printf 'Usage: %s report|preflight|download|prepare\n' "$0" >&2; exit 2 ;;
esac
