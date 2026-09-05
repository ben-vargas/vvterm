#!/usr/bin/env python3
"""Check bundled localization coverage, duplicate keys, and format arguments."""
import collections
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', re.M)
FORMAT = re.compile(r'%(?:([1-9]\d*)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hlLzjtq])?([@diuoxXfFeEgGaAcCsSpn%])')
SOURCE_KEY = re.compile(r'(?:String\s*\(\s*localized\s*:|NSLocalizedString\s*\(|LocalizedFormat\.string\s*\()\s*"((?:[^"\\]|\\.)*)"')
TECHNICAL_NAMES = {'CPU', 'GPU', 'SSH', 'SFTP', 'Docker', 'Swift', 'Markdown', 'JavaScript', 'TypeScript', 'Python', 'JSON', 'YAML', 'NVMe', 'SMART', 'ZFS', 'tmux', 'mosh-server', 'Whisper', 'Parakeet', 'Ghostty', 'Mosh', 'Pro'}


def check_plurals(path, strings, errors):
    values = plistlib.loads(path.read_bytes())
    for key, entry in values.items():
        if key not in strings:
            errors.append(f'{path.relative_to(ROOT)}: plural key absent from strings: {key!r}')
        if entry.get('NSStringLocalizedFormatKey') != '%#@count@':
            errors.append(f'{path.relative_to(ROOT)}: unsupported plural format for {key!r}')
        rule = entry.get('count', {})
        if rule.get('NSStringFormatSpecTypeKey') != 'NSStringPluralRuleType' or rule.get('NSStringFormatValueTypeKey') != 'lld':
            errors.append(f'{path.relative_to(ROOT)}: invalid count rule for {key!r}')
        forms = {k: v for k, v in rule.items() if not k.startswith('NSString')}
        if 'other' not in forms:
            errors.append(f'{path.relative_to(ROOT)}: missing other form for {key!r}')
        for category, value in forms.items():
            if not value.strip() or arguments(value) != [(1, 'lld')]:
                errors.append(f'{path.relative_to(ROOT)}: invalid {category} form for {key!r}')
    return set(values)


def leaves(value, prefix=''):
    if isinstance(value, dict):
        return {key: item for name, child in value.items() for key, item in leaves(child, f'{prefix}.{name}').items()}
    if isinstance(value, list):
        return {key: item for index, child in enumerate(value) for key, item in leaves(child, f'{prefix}[{index}]').items()}
    return {prefix: value}


def arguments(value):
    result = []
    position = 0
    for match in FORMAT.finditer(value):
        if match[3] == '%':
            continue
        position += 1
        result.append((int(match[1] or position), (match[2] or '') + match[3]))
    return sorted(result)


def read_strings(path, errors):
    raw = path.read_text()
    counts = collections.Counter(match[1] for match in ENTRY.finditer(raw))
    for key, count in counts.items():
        if count != 1:
            errors.append(f'{path.relative_to(ROOT)}: duplicate key {key!r}')
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], capture_output=True, text=True)
    if result.returncode:
        errors.append(f'{path.relative_to(ROOT)}: {result.stderr or result.stdout}')
        return {}
    values = json.loads(result.stdout)
    if len(values) != len(counts):
        errors.append(f'{path.relative_to(ROOT)}: unsupported entry syntax')
    for key, value in values.items():
        if not value.strip():
            errors.append(f'{path.relative_to(ROOT)}: empty value for {key!r}')
    return values


def main():
    errors = []
    files = {}
    for owner in ['VVTerm', 'VVTermLiveActivity']:
        for path in sorted((ROOT / owner / 'Resources').glob('*.lproj/*.strings')):
            files[path] = read_strings(path, errors)
    for path, values in files.items():
        reference = files[path.parent.parent / 'en.lproj' / path.name]
        for key in sorted(reference.keys() - values.keys()):
            errors.append(f'{path.relative_to(ROOT)}: missing {key!r}')
        for key in sorted(values.keys() - reference.keys()):
            errors.append(f'{path.relative_to(ROOT)}: extra {key!r}')
        for key in reference.keys() & values.keys():
            if arguments(reference[key]) != arguments(values[key]):
                errors.append(f'{path.relative_to(ROOT)}: format mismatch for {key!r}')
            # Ordinary prose may use a standard local term. Product, protocol,
            # command, and file-format names must remain recognizable.
            for name in TECHNICAL_NAMES - {'CPU'}:
                if re.search(r'\b' + re.escape(name) + r'\b', reference[key]) and name not in values[key]:
                    errors.append(f'{path.relative_to(ROOT)}: missing technical name {name!r} in {key!r}')
        for name in TECHNICAL_NAMES & reference.keys():
            if reference[name] == name and values.get(name) != name:
                errors.append(f'{path.relative_to(ROOT)}: technical label changed: {name!r}')
    plurals = {}
    for owner in ['VVTerm', 'VVTermLiveActivity']:
        for path in sorted((ROOT / owner / 'Resources').glob('*.lproj/*.stringsdict')):
            plurals[path] = check_plurals(path, files[path.with_suffix('.strings')], errors)
    for path, keys in plurals.items():
        if keys != plurals[path.parent.parent / 'en.lproj' / path.name]:
            errors.append(f'{path.relative_to(ROOT)}: plural key coverage differs from English')
    english = files[ROOT / 'VVTerm/Resources/en.lproj/Localizable.strings']
    for path in sorted((ROOT / 'VVTerm').rglob('*.swift')):
        for match in SOURCE_KEY.finditer(path.read_text()):
            if '\\(' in match[1]:
                continue  # Interpolated Swift strings need compiler extraction.
            key = json.loads('"' + match[1] + '"')
            if key not in english:
                errors.append(f'{path.relative_to(ROOT)}: source key missing from catalog: {key!r}')
    required_permissions = {'NSFaceIDUsageDescription', 'NSLocalNetworkUsageDescription', 'NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'}
    for path, values in files.items():
        if path.name == 'InfoPlist.strings':
            for key in sorted(required_permissions - values.keys()):
                errors.append(f'{path.relative_to(ROOT)}: missing permission {key}')
    web_root = ROOT / 'web/src/i18n/translations'
    web_reference = leaves(json.loads((web_root / 'en.json').read_text()))
    for path in sorted(web_root.glob('*.json')):
        values = leaves(json.loads(path.read_text()))
        if values.keys() != web_reference.keys():
            errors.append(f'{path.relative_to(ROOT)}: website key coverage differs from English')
        for key in values.keys() & web_reference.keys():
            if re.findall(r'\d+(?:\.\d+)?', str(values[key])) != re.findall(r'\d+(?:\.\d+)?', str(web_reference[key])):
                errors.append(f'{path.relative_to(ROOT)}: website numbers differ for {key}')
    for error in errors[:30]:
        print(error)
    if errors:
        print(f'FAILED: {len(errors)} localization errors (first 30 shown).')
        return 1
    print(f'PASS: {len(files)} string files, {len(plurals)} plural files, and website dictionaries; coverage, arguments, technical names, and permissions.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
