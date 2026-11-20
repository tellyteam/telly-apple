#!/usr/bin/env python3
"""Shows how telly is doing on TestFlight: recent builds, who has them, installs, sessions,
crashes and tester feedback.

Usage: python3 scripts/testflight-status.py [number of builds, default 5]

Needs an App Store Connect API key (Users and Access → Integrations → App Store Connect API) in
the same variables scripts/testflight.sh uses: ASC_KEY_PATH (the .p8 file), ASC_KEY_ID,
ASC_ISSUER_ID. The Developer role is enough. Only the Python standard library and openssl are used.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

BUNDLE_ID = "app.gettelly.telly"
API = "https://api.appstoreconnect.apple.com"


def token():
    try:
        kid, iss = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
        key = os.path.expanduser(os.environ["ASC_KEY_PATH"])
    except KeyError as missing:
        sys.exit(f"Set {missing.args[0]} (and the other ASC_ variables) to an App Store Connect API key.")

    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=")

    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": iss, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}).encode())
    signed = header + b"." + claims
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=signed,
                         capture_output=True, check=True).stdout
    # openssl gives a DER signature; a JWT wants the two 32-byte numbers side by side.
    i = 3 if der[1] & 0x80 else 2
    parts = []
    for _ in range(2):
        length = der[i + 1]
        parts.append(der[i + 2:i + 2 + length][-32:].rjust(32, b"\0"))
        i += 2 + length
    return (signed + b"." + b64(parts[0] + parts[1])).decode()


TOKEN = None


def get(path, **query):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return {"data": []}
        detail = error.read().decode()[:300]
        sys.exit(f"App Store Connect said {error.code} for {path}: {detail}")


def day(stamp):
    """Apple's times carry their own offset (usually Pacific); show them in this Mac's time zone."""
    if not stamp:
        return "?"
    return datetime.fromisoformat(stamp).astimezone().strftime("%Y-%m-%d %H:%M")


SHORT_STATES = {
    "READY_FOR_BETA_SUBMISSION": "not submitted",
    "WAITING_FOR_BETA_REVIEW": "waiting for review",
    "IN_BETA_REVIEW": "in review",
    "BETA_APPROVED": "approved",
    "BETA_REJECTED": "rejected",
    "IN_BETA_TESTING": "testing",
    "IN_EXPORT_COMPLIANCE_REVIEW": "compliance review",
    "MISSING_EXPORT_COMPLIANCE": "needs compliance",
    "PROCESSING_EXCEPTION": "processing failed",
}


def main():
    global TOKEN
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    TOKEN = token()

    apps = get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(f"No app with bundle id {BUNDLE_ID} on this account.")
    app = apps[0]["id"]

    # Which groups have which builds.
    groups = get(f"/v1/apps/{app}/betaGroups")["data"]
    in_group = {}
    for group in groups:
        for build in get(f"/v1/betaGroups/{group['id']}/builds", limit=200)["data"]:
            in_group.setdefault(build["id"], []).append(group["attributes"]["name"])

    builds = get("/v1/builds", **{"filter[app]": app, "sort": "-uploadedDate", "limit": count,
                                  "include": "preReleaseVersion,buildBetaDetail"})
    included = {(x["type"], x["id"]): x["attributes"] for x in builds.get("included", [])}

    def related(build, name, kind):
        data = build.get("relationships", {}).get(name, {}).get("data") or {}
        return included.get((kind, data.get("id")), {})

    print(f"telly on TestFlight ({BUNDLE_ID})\n")
    columns = "{:<9} {:<13} {:<17} {:<18} {:<14} {:>8} {:>8} {:>7} {:>8}"
    print(columns.format("Version", "Build", "Uploaded", "External", "Groups",
                         "Installs", "Sessions", "Crashes", "Feedback"))
    newest_version = None
    for build in builds["data"]:
        attrs = build["attributes"]
        version = related(build, "preReleaseVersion", "preReleaseVersions").get("version", "?")
        newest_version = newest_version or version
        beta = related(build, "buildBetaDetail", "buildBetaDetails")
        state = beta.get("externalBuildState", "?")
        external = SHORT_STATES.get(state, state.replace("_", " ").lower())
        if attrs.get("processingState") != "VALID":
            external = attrs.get("processingState", "?").lower()
        if attrs.get("expired"):
            external = "expired"
        usage = get(f"/v1/builds/{build['id']}/metrics/betaBuildUsages")["data"]
        values = (usage[0]["dataPoints"][0]["values"] if usage and usage[0].get("dataPoints") else {})
        print(columns.format(version, attrs["version"], day(attrs.get("uploadedDate")), external,
                             ", ".join(in_group.get(build["id"], [])) or "-",
                             values.get("installCount", 0), values.get("sessionCount", 0),
                             values.get("crashCount", 0), values.get("feedbackCount", 0)))

    versions = [related(b, "preReleaseVersion", "preReleaseVersions").get("version", "") for b in builds["data"]]

    def as_tuple(v):
        return tuple(int(p) if p.isdigit() else 0 for p in v.split("."))

    highest = max(versions, key=as_tuple, default="")
    if newest_version and highest and as_tuple(newest_version) < as_tuple(highest):
        print(f"\nThe newest upload is version {newest_version}, lower than {highest}: "
              "testers on the higher version won't see it as an update.")

    testers = get("/v1/betaTesters", **{"filter[apps]": app, "limit": 200})["data"]
    states = {}
    for tester in testers:
        state = (tester["attributes"].get("state") or "?").replace("_", " ").lower()
        states[state] = states.get(state, 0) + 1
    print(f"\nTesters: {len(testers)}" + (" (" + ", ".join(f"{n} {s}" for s, n in sorted(states.items())) + ")" if states else ""))
    for group in groups:
        attrs = group["attributes"]
        kind = "internal" if attrs.get("isInternalGroup") else "external"
        link = ", public link on" if attrs.get("publicLinkEnabled") else ""
        print(f"  {attrs['name']}: {kind}{link}")

    for kind, label in (("betaFeedbackCrashSubmissions", "Crash reports from testers"),
                        ("betaFeedbackScreenshotSubmissions", "Screenshot feedback")):
        items = get(f"/v1/apps/{app}/{kind}", limit=10)["data"]
        print(f"\n{label}: {len(items)}" + (" (latest 10)" if len(items) == 10 else ""))
        for item in items:
            attrs = item["attributes"]
            comment = (attrs.get("comment") or "").replace("\n", " ")
            print(f"  {day(attrs.get('createdDate'))}  {attrs.get('deviceModel', '?')} "
                  f"iOS {attrs.get('osVersion', '?')}  {comment[:100]}")

    print("\nFull crash logs: Xcode → Window → Organizer → Crashes.")


if __name__ == "__main__":
    main()
