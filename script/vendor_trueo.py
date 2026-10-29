#!/usr/bin/env python3
"""Copies Trueo's verified project sources (Sourcify exact match, Base 8453) into src/trueo/ byte for byte.

Only the project's own files (paths under src/ in the Sourcify bundle) are copied; library files come from lib/.
Usage (from the repo root): python3 script/vendor_trueo.py && (cd src/trueo && shasum -a 256 -c ../../vendor/trueo.sha256)
"""
import json
import os
import urllib.request

SOURCIFY = "https://sourcify.dev/server/v2/contract/8453/{}?fields=sources"
TARGETS = {
    "hook": "0x3E83479B2276EcFb7C7181F67b5d092d3511e0C4",  # TruthMarketHook
    "validator": "0x55e26CF92B924C069db4d8Da7B0b36154374Dd38",  # TruthMarketSwapValidator
}


def project_files(sources):
    return {k[len("src/"):]: v["content"] for k, v in sources.items() if k.startswith("src/")}


def main():
    for name, address in TARGETS.items():
        with urllib.request.urlopen(SOURCIFY.format(address), timeout=60) as r:
            bundle = json.loads(r.read())
        for rel, content in sorted(project_files(bundle["sources"]).items()):
            path = os.path.join("src", "trueo", name, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", newline="") as f:
                f.write(content)
            print(path)


if __name__ == "__main__":
    main()
