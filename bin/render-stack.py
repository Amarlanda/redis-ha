#!/usr/bin/env python3
"""render-stack.py — render deploy/specs/*.json.j2 for redis-ha.

Modeled on cv-stack/bin/render-stack.py but specialized for the
single-cluster, multi-replica case:
  - One spec template (redis-ha.json.j2) → one rendered spec
  - Replicas: spec declares `replicas: 2` so the orchestrator does
    placement; we allocate one IP per replica (`redis-ha-0`,
    `redis-ha-1`) because the spec needs both for replica_ips and
    primary health-probe.

Usage:
    ./bin/render-stack.py prod
    ./bin/render-stack.py prod --output-dir out/
    ./bin/render-stack.py prod --no-allocate    # values yaml supplies all IPs

Env vars:
    DEPLOY_HOST           default https://deploy-m3.amarlanda.com
    DEPLOY_RUNNER_TOKEN   bearer token for /allocate-ip calls
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.request
import urllib.error
from pathlib import Path

try:
    import yaml
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError:
    print("missing deps — pip install pyyaml jinja2", file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
SPECS_DIR = ROOT / "deploy" / "specs"
STACKS_DIR = ROOT / "stacks"

# macOS framework Python ships with an empty CA bundle by default;
# point at the brew openssl bundle so the deploy-mN.amarlanda.com
# Cloudflare cert verifies. CI Linux has a working default so the
# fallback (None) is fine there.
_CAFILE = "/opt/homebrew/etc/openssl@3/cert.pem"
_SSL_CTX = ssl.create_default_context(cafile=_CAFILE) if os.path.exists(_CAFILE) else None


def allocate_ip(deploy_host: str, token: str, name: str) -> str:
    """POST /allocate-ip/<name>. Idempotent — same name → same IP."""
    req = urllib.request.Request(
        f"{deploy_host.rstrip('/')}/allocate-ip/{name}",
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": "redis-ha/render-stack.py",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10, context=_SSL_CTX) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise SystemExit(f"allocate-ip {name} → {e.code}: {body}")
    if "ip" not in data:
        raise SystemExit(f"allocate-ip {name} returned no ip: {data}")
    return data["ip"]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("stack", nargs="?", default="prod")
    p.add_argument("--output-dir", help="write rendered specs here")
    p.add_argument("--no-allocate", action="store_true",
                   help="skip auto-IP allocation; values yaml must supply all IPs")
    args = p.parse_args()

    values_path = STACKS_DIR / f"{args.stack}.yaml"
    if not values_path.exists():
        raise SystemExit(f"no values file at {values_path}")
    values = yaml.safe_load(values_path.read_text()) or {}
    stack_name = values.get("stack") or args.stack

    # Auto-allocate IPs for every `ips:` key whose value is empty.
    # Convention: declare `redis-ha-0: ""` and `redis-ha-1: ""` in
    # stacks/prod.yaml — the renderer fills them in via deploy-runner.
    # Pre-filled (non-empty) values are kept as-is, so a one-time
    # hand-allocated IP can be locked in by writing it back to the yaml.
    ips = dict(values.get("ips") or {})
    if not args.no_allocate:
        token = os.environ.get("DEPLOY_RUNNER_TOKEN")
        deploy_host = os.environ.get("DEPLOY_HOST", "https://deploy-m3.amarlanda.com")
        if not token:
            raise SystemExit("DEPLOY_RUNNER_TOKEN env var required for IP allocation (or pass --no-allocate)")
        for name in list(ips.keys()):
            if ips[name]:
                continue
            ips[name] = allocate_ip(deploy_host, token, name)
            print(f"# allocated {name} → {ips[name]}", file=sys.stderr)

    # Vault loading — same contract as cv-stack render. Local dev:
    # ansible-vault view from the sibling ansible-local repo. CI:
    # VAULT_* env vars override (GitHub Actions secrets path).
    vault_values: dict[str, str] = {
        # Default empty so missing secrets render as empty string and
        # the entrypoint surfaces a clear "REDIS_PASSWORD required"
        # rather than Jinja StrictUndefined.
        "vault_redis_password": "",
    }
    vault_yml = ROOT.parent / "ansible-local" / "group_vars" / "all" / "vault.yml"
    vault_pw = ROOT.parent / "ansible-local" / ".vault_pass"
    ansible_vault_bin = ROOT.parent / "ansible-local" / "venv" / "bin" / "ansible-vault"
    if vault_yml.exists() and vault_pw.exists() and ansible_vault_bin.exists():
        import subprocess
        try:
            out = subprocess.check_output(
                [str(ansible_vault_bin), "view",
                 "--vault-password-file", str(vault_pw),
                 str(vault_yml)],
                text=True, timeout=10,
            )
            for line in out.splitlines():
                line = line.strip()
                if not line or line.startswith("#") or ":" not in line:
                    continue
                key, _, val = line.partition(":")
                key = key.strip()
                if key.startswith("vault_"):
                    vault_values[key] = val.strip().strip('"').strip("'")
        except Exception as e:
            print(f"# vault load failed: {e}", file=sys.stderr)
    for k, v in os.environ.items():
        if k.startswith("VAULT_"):
            vault_values[k.lower()] = v

    # Resource coercion — same trick cv-stack uses. Job.Resources.CPU
    # is a Go string; YAML coerces bare numbers to int → tojson emits
    # int → unmarshal fails silently → scheduler ignores the job. So
    # force string here.
    raw_resources = values.get("resources") or {}
    coerced_resources: dict = {}
    for svc, budget in raw_resources.items():
        out: dict = {}
        for kind in ("requests", "limits"):
            block = (budget or {}).get(kind) or {}
            out[kind] = {k: str(v) for k, v in block.items()}
        coerced_resources[svc] = out

    env = Environment(
        loader=FileSystemLoader(str(SPECS_DIR)),
        undefined=StrictUndefined,
        trim_blocks=False,
        lstrip_blocks=False,
    )

    out_dir = Path(args.output_dir) if args.output_dir else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    context = {
        "stack": stack_name,
        "nodes": values.get("nodes") or {},
        "resources": coerced_resources,
        "images": values.get("images") or {},
        "ips": ips,
        **vault_values,
    }

    rendered_any = False
    for tmpl_path in sorted(SPECS_DIR.glob("*.json.j2")):
        svc = tmpl_path.stem.replace(".json", "")
        rendered = env.get_template(tmpl_path.name).render(**context)
        try:
            parsed = json.loads(rendered)
        except json.JSONDecodeError as e:
            print(f"--- rendered {svc}: ---\n{rendered}", file=sys.stderr)
            raise SystemExit(f"rendered {svc} is not valid JSON: {e}")
        canonical = json.dumps(parsed, indent=2, sort_keys=False) + "\n"
        # Use the spec's "name" field as the file/service name so we
        # don't double-prefix when stack=prod and service=redis-ha.
        # postgres-ha-equivalent name: just `redis-ha`.
        out_name = parsed.get("name", svc)
        if out_dir:
            (out_dir / f"{out_name}.json").write_text(canonical)
        else:
            print(f"# === {out_name} ===")
            print(canonical)
        rendered_any = True

    if not rendered_any:
        raise SystemExit("nothing rendered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
