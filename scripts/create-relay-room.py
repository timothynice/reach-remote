#!/usr/bin/env python3
"""Create private self-hosted relay material without printing credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
from urllib.parse import urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--url', required=True, help='Public wss://hostname/tunnel endpoint')
parser.add_argument('--output', required=True, type=Path, help='New private directory outside the repository')
args = parser.parse_args()
try:
    endpoint = urlsplit(args.url)
    if (endpoint.scheme != 'wss' or not endpoint.hostname or endpoint.username is not None
            or endpoint.password is not None or endpoint.query or endpoint.fragment
            or endpoint.path != '/tunnel' or len(args.url) > 2048):
        raise ValueError()
    endpoint.port  # Validate port syntax/range before creating any files.
except ValueError:
    parser.error('--url must be a WSS /tunnel endpoint without credentials, query or fragment')
output = args.output.expanduser().resolve()
repository = Path(__file__).resolve().parents[1]
if output == repository or repository in output.parents:
    parser.error('--output must be outside the repository')
os.umask(0o077)
try:
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
except FileExistsError:
    parser.error('--output already exists; choose a fresh directory to avoid replacing credentials')
room = secrets.token_hex(32)
(output / 'configuration.json').write_text(json.dumps({'url': args.url, 'room': room}, indent=2) + '\n')
(output / 'allowed-rooms').write_text(hashlib.sha256(room.encode()).hexdigest() + '\n')
print('Created private configuration.json and allowed-rooms. No credentials printed.')
print('Transfer only allowed-rooms to the server; configure the Mac from configuration.json locally.')
