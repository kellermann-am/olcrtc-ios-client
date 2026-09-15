#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Runner-side ASC provisioning: register optional device, regenerate both
ad-hoc profiles with ALL enabled iOS devices, write .mobileprovision files.
Env: ASC_P8_BASE64, ASC_KEY_ID, ASC_ISSUER_ID, ASC_BUNDLE_APP, ASC_BUNDLE_EXT,
ASC_CERT_ID, OUT_DIR, optional ENROLL_UDID, ENROLL_NAME."""
import base64, json, os, time, pathlib
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils as au

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
P8 = base64.b64decode(os.environ["ASC_P8_BASE64"])
BUNDLE_APP = os.environ["ASC_BUNDLE_APP"]
BUNDLE_EXT = os.environ["ASC_BUNDLE_EXT"]
CERT_ID = os.environ["ASC_CERT_ID"]
OUT = pathlib.Path(os.environ.get("OUT_DIR", "."))
UDID = os.environ.get("ENROLL_UDID", "").strip()
NAME = os.environ.get("ENROLL_NAME", "").strip()
BASE = "https://api.appstoreconnect.apple.com"


def _b(x):
    return base64.urlsafe_b64encode(x).rstrip(b"=")


def token():
    key = serialization.load_pem_private_key(P8, password=None)
    now = int(time.time())
    h = _b(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    p = _b(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 900,
                       "aud": "appstoreconnect-v1"}).encode())
    der = key.sign(h + b"." + p, ec.ECDSA(hashes.SHA256()))
    r, s = au.decode_dss_signature(der)
    sig = _b(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    return (h + b"." + p + b"." + sig).decode()


def H():
    return {"Authorization": "Bearer " + token(), "Content-Type": "application/json"}


def get(path, params=None):
    return requests.get(BASE + path, headers=H(), params=params, timeout=30)


def register_device(udid, name):
    body = {"data": {"type": "devices", "attributes": {
        "name": name or ("Device " + udid[:8]), "platform": "IOS", "udid": udid}}}
    r = requests.post(BASE + "/v1/devices", headers=H(), json=body, timeout=30)
    print("register device %s -> HTTP %s" % (udid, r.status_code))
    # 409/conflict means already registered - fine
    return r.status_code in (200, 201, 409)


def enabled_device_ids():
    r = get("/v1/devices", {"limit": 200})
    return [x["id"] for x in r.json()["data"]
            if x["attributes"].get("status") == "ENABLED"
            and x["attributes"].get("platform") == "IOS"]


def regen(name_base, bundle_id, dev_ids):
    # delete existing profiles with this base name
    r = get("/v1/profiles", {"limit": 200})
    for x in r.json().get("data", []):
        if x["attributes"].get("name", "").startswith(name_base):
            requests.delete(BASE + "/v1/profiles/" + x["id"], headers=H(), timeout=30)
    name = "%s %d" % (name_base, int(time.time()))
    body = {"data": {"type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_ADHOC"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": CERT_ID}]},
                "devices": {"data": [{"type": "devices", "id": i} for i in dev_ids]}}}}
    r = requests.post(BASE + "/v1/profiles", headers=H(), json=body, timeout=30)
    if r.status_code not in (200, 201):
        raise SystemExit("profile create failed %s: %s" % (r.status_code, r.text[:300]))
    return base64.b64decode(r.json()["data"]["attributes"]["profileContent"])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if UDID:
        register_device(UDID, NAME)
    devs = enabled_device_ids()
    print("enabled devices:", len(devs))
    (OUT / "app.mobileprovision").write_bytes(regen("OlcRTC AdHoc App", BUNDLE_APP, devs))
    (OUT / "ext.mobileprovision").write_bytes(regen("OlcRTC AdHoc Tunnel", BUNDLE_EXT, devs))
    print("wrote app.mobileprovision + ext.mobileprovision to", OUT)


if __name__ == "__main__":
    main()
