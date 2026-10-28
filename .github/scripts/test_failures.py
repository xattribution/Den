"""Prints each failed test in a `dart test` / `flutter test` JSON report as a GitHub error
annotation, so failures show on the pull request and through the checks API without the log.

Usage: python .github/scripts/test_failures.py <report.jsonl>
"""

import json
import os
import sys


def escape(text):
    return text.replace('%', '%25').replace('\r', '').replace('\n', '%0A')


def escape_property(text):
    return escape(text).replace(':', '%3A').replace(',', '%2C')


def main(path):
    if not os.path.exists(path):
        return
    workspace = os.environ.get('GITHUB_WORKSPACE', os.getcwd()).rstrip('/') + '/'
    tests = {}
    errors = {}
    prints = {}
    failed = []
    with open(path, encoding='utf-8') as report:
        for line in report:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get('type')
            if kind == 'testStart':
                tests[event['test']['id']] = event['test']
            elif kind == 'error':
                errors.setdefault(event['testID'], []).append(event)
            elif kind == 'print':
                # Flutter prints the exception itself and reports "See exception logs above".
                prints.setdefault(event['testID'], []).append(event.get('message') or '')
            elif kind == 'testDone' and event.get('result') != 'success' and not event.get('hidden'):
                failed.append(event['testID'])
    for test_id in failed[:10]:
        test = tests.get(test_id, {})
        url = test.get('root_url') or test.get('url') or ''
        line = test.get('root_line') or test.get('line') or 1
        file = url.replace('file://', '').replace(workspace, '')
        logged = '\n'.join(prints.get(test_id, [])).splitlines()
        message = '\n\n'.join(
            ['\n'.join(line for line in logged if line.strip() and not line.startswith('═'))[:3000]] + [
                (e.get('error') or '') + '\n' + '\n'.join((e.get('stackTrace') or '').splitlines()[:12])
                for e in errors.get(test_id, [])
            ]
        ).strip()[:6000]
        print('::error file=%s,line=%s,title=%s::%s' % (
            escape_property(file), line, escape_property(test.get('name', 'test')[:200]), escape(message or 'failed')))


if __name__ == '__main__':
    main(sys.argv[1])
