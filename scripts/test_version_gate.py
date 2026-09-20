# -*- coding: utf-8 -*-
r"""Does the version gate actually fail when it should?

    python scripts/test_version_gate.py

WHY A TEST FOR A CHECK
    verify_hap.py's first step compares the file name, the artifactName, the
    versionName and the versionCode, because those four live in four files that
    get edited at different times. That check is only worth having if it is
    known to reject a bad package -- and this project has already shipped one
    "gate" that printed OK unconditionally, because a pipeline's exit status was
    being thrown away before it was read.

    So: build minimal packages holding nothing but pack.info, tamper with one
    field at a time, and run the real gate function over each.

    The first run failed its own good case and the fault was in this file, not
    in the gate: the harness wrote every package under a scratch name and passed
    the intended name separately, and the gate compares the file's actual name.
    Worth recording, because "the check is broken" and "my test is broken" look
    identical from the output.

WHEN TO RUN IT
    After touching the version fields, and after touching that gate.
"""
# Negative test for the version gate.
#
# Builds minimal .hap files (a zip holding nothing but pack.info) with the
# version fields tampered, then runs the REAL gate function from verify_hap.py
# against each one. A gate that has never been shown to fail is not yet known to
# be a gate -- this project has already shipped one check that always printed OK
# because the pipeline's exit status was being discarded.
import io
import json
import os
import sys
import zipfile

# Derived from this file's own location, not written down. It used to be a
# literal absolute path to one particular checkout, which is the one thing every
# other script in here deliberately avoids -- they all route through config.py,
# whose paths are ARK_*-overridable defaults. The literal meant a checkout
# anywhere else failed with a confusing ImportError, and the repository carried
# a path belonging to one machine for no reason.
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "scripts"))
os.chdir(HERE)

import config
import verify_hap

GOOD = {
    "summary": {"app": {"version": {"name": config.APP_VERSION,
                                    "code": config.VERSION_CODE}}},
    "packages": [{"name": config.ARTIFACT_NAME}],
}


def make_hap(path, info):
    """Write a minimal package AT the given path.

    The path's basename is part of what the gate checks, so the file has to
    actually carry the name under test -- writing it under a scratch name and
    passing the intended one separately made the good case fail, which was the
    harness being wrong rather than the gate.
    """
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("pack.info", json.dumps(info))
    return path


def run_case(label, filename, patch, expect_fail):
    info = json.loads(json.dumps(GOOD))          # deep copy
    patch(info)
    p = make_hap(os.path.join(os.environ["TEMP"], filename), info)
    ok = [True]
    print("--- %s" % label)
    print("    expecting: %s" % ("FAIL" if expect_fail else "PASS"))
    verify_hap.check_version_matches_name(p, ok)
    got = not ok[0]
    verdict = "as expected" if got == expect_fail else "*** WRONG ***"
    print("    result   : %s   %s" % ("FAIL" if got else "PASS", verdict))
    os.remove(p)
    return got == expect_fail


base = config.ARTIFACT_NAME
cases = [
    ("good", base + "-unsigned.hap", lambda i: None, False),
    ("wrong-code",
     base + "-unsigned.hap",
     lambda i: i["summary"]["app"]["version"].__setitem__("code", 1000000),
     True),
    ("code-is-final-release-value",
     base + "-unsigned.hap",
     lambda i: i["summary"]["app"]["version"].__setitem__(
         "code", config.version_code_for("0.1.0")),
     True),
    ("wrong-versionName",
     base + "-unsigned.hap",
     lambda i: i["summary"]["app"]["version"].__setitem__("name", "0.1.0-beta2"),
     True),
    ("wrong-artifactName",
     base + "-unsigned.hap",
     lambda i: i["packages"][0].__setitem__("name", "MindustryArk-v9.9.9"),
     True),
    ("file-name-mismatch",
     "MindustryArk-v1.0.0-unsigned.hap",
     lambda i: None,
     True),
    ("unexpected-artifact-name",
     base + "-signed.hap",
     lambda i: None,
     True),
]

results = [run_case(*c) for c in cases]
print()
print("negative test: %d/%d as expected" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
