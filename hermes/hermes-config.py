#!/usr/bin/env python3
"""Configure Hermes settings at image build time.

Modifies config.yaml directly instead of shelling out to `hermes config set`,
which avoids issues with HOME detection. Run update-config-hashes.py after
this to regenerate NemoClaw's integrity hashes.
"""
import yaml

CONFIG_PATH = "/sandbox/.hermes/config.yaml"

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
    with open(CONFIG_PATH) as f:
        cfg = yaml.safe_load(f)

    deep_merge(cfg, SETTINGS)
    # VM image is Hermes + ddgs only — no remote MCP servers.
    cfg["mcp_servers"] = {}
    # A leftover providers/custom_providers entry named "custom" hijacks
    # resolve_runtime_provider() and ignores model.api_mode (Hermes falls
    # back to chat_completions → POST /v1/chat/completions, which Vertex
    # Claude does not route). Clear both so model.* is authoritative.
    cfg.pop("providers", None)
    cfg.pop("custom_providers", None)

    with open(CONFIG_PATH, "w") as f:
        yaml.dump(cfg, f, default_flow_style=False)

    print("Hermes config updated:")
    for k, v in SETTINGS.items():
        print(f"  {k}: {v}")
    print("  mcp_servers: []")
    print("  providers/custom_providers: cleared")


if __name__ == "__main__":
    main()
