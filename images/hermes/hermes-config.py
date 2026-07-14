#!/usr/bin/env python3
"""Configure Hermes settings at image build time.

Modifies (or creates) config.yaml directly instead of shelling out to
`hermes config set`, which avoids issues with HOME detection.

NemoClaw variant: run update-config-hashes.py after this to regenerate
integrity hashes. Hermes-minimal skips that step (mutable config).
"""
from pathlib import Path

import yaml

CONFIG_PATH = Path("/sandbox/.hermes/config.yaml")

# Hermes >=0.18 ignores model.base_url for provider: anthropic unless the host
# looks like Anthropic/Azure/…/anthropic — inference.local fails that guard and
# falls back to api.anthropic.com (denied by OpenShell policy). Use custom +
# anthropic_messages so OpenShell's inference.local proxy is honored.
SETTINGS = {
    "model": {
        "default": "claude-opus-4-6",
        "provider": "custom",
        "base_url": "https://inference.local",
        "api_key": "sk-OPENSHELL-PROXY-REWRITE",
        "api_mode": "anthropic_messages",
    },
    "platforms": {
        "discord": {"enabled": False},
        "signal": {"enabled": True},
        "slack": {"enabled": True},
    },
    "web": {
        "backend": "ddgs",
    },
}


def deep_merge(base, override):
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v


def main():
    if CONFIG_PATH.exists():
        with CONFIG_PATH.open() as f:
            cfg = yaml.safe_load(f) or {}
    else:
        cfg = {}

    deep_merge(cfg, SETTINGS)
    # Lean image default — no remote MCP servers baked in.
    cfg["mcp_servers"] = {}
    # A leftover providers/custom_providers entry named "custom" hijacks
    # resolve_runtime_provider() and ignores model.api_mode (Hermes falls
    # back to chat_completions → POST /v1/chat/completions, which Vertex
    # Claude does not route). Clear both so model.* is authoritative.
    cfg.pop("providers", None)
    cfg.pop("custom_providers", None)

    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CONFIG_PATH.open("w") as f:
        yaml.dump(cfg, f, default_flow_style=False)

    print("Hermes config updated:")
    for k, v in SETTINGS.items():
        print(f"  {k}: {v}")
    print("  mcp_servers: []")
    print("  providers/custom_providers: cleared")


if __name__ == "__main__":
    main()
