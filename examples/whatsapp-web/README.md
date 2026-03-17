# WhatsApp Web External Plugin Example

This directory contains a reference adapter for `channels.external`:

- `nullclaw-plugin-whatsapp-web`
  Converts the ExternalChannel JSON-RPC/stdio plugin protocol into the
  HTTP bridge contract from the whatsmeow example (`/health`, `/poll`, `/send`).
  The adapter advertises `protocol_version=2` and `capabilities.health=true`
  in `get_manifest`.
  `config.bridge_url` must be `https://...` or loopback `http://127.0.0.1/...`.

Typical config:

```json
{
  "channels": {
    "external": {
      "accounts": {
        "wa-web": {
          "runtime_name": "whatsapp_web",
          "transport": {
            "command": "/absolute/path/to/examples/whatsapp-web/nullclaw-plugin-whatsapp-web",
            "timeout_ms": 10000
          },
          "config": {
            "bridge_url": "http://127.0.0.1:3301",
            "allow_from": ["*"],
            "group_policy": "allowlist"
          }
        }
      }
    }
  }
}
```

Optional `config` keys understood by the adapter:

- `api_key`
- `allow_from`
- `group_allow_from`
- `group_policy`
- `poll_interval_ms`
- `timeout_ms`

Protocol notes:

- `start.params.runtime` contains `name`, `account_id`, and host-owned `state_dir`
- `send.params` contains nested `runtime` and `message` objects
- `inbound_message.params` contains a nested `message` object
- `health.result` must return `healthy` or explicit boolean health signals; `{}` is invalid
