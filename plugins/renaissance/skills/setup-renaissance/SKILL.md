---
name: setup-renaissance
description: Set up the Renaissance AR CLI tool. Use when user says "/setup-renaissance" or when renaissance commands fail with config errors.
tools: Bash
---

# Setup Renaissance CLI

Interactive setup for the `renaissance` CLI tool that checks Accelerated Reader progress.
Uses pure curl for authentication (no browser/Playwright needed). Supports multiple students.

## Steps

1. **Install fnox** (if not already):
```bash
mise install fnox
```

2. **Symlink the CLI:**
```bash
ln -sf ~/Code/github.com/ericboehs/agent-plugins/plugins/renaissance/bin/renaissance ~/bin/renaissance
```

3. **Create config directory:**
```bash
mkdir -p ~/.config/renaissance
```

4. **Store credentials in fnox** (one per student):
```bash
fnox set RENAISSANCE_KID1_USERNAME "student_username" --provider keychain --global
fnox set RENAISSANCE_KID1_PASSWORD "student_password" --provider keychain --global
fnox set RENAISSANCE_KID2_USERNAME "student_username" --provider keychain --global
fnox set RENAISSANCE_KID2_PASSWORD "student_password" --provider keychain --global
```

5. **Write config** at `~/.config/renaissance/config.json`:
```json
{
  "school_id": "6e86d58e-91b4-4b66-8620-a24a71751415",
  "realm_id": "10955dcf-583c-4c4d-8e9c-eb0ca12c2ef4",
  "rpid": "CPS-88RB",
  "client_id": "341411",
  "students": [
    {
      "name": "Allie",
      "credentials_key": "KID1",
      "user_id": "7fecd686-7cef-46d6-b557-fef2a819f01d"
    },
    {
      "name": "Layla",
      "credentials_key": "KID2",
      "user_id": ""
    }
  ]
}
```

6. **Test it:**
```bash
renaissance login allie
renaissance goals allie
```

## Adding a new student

1. Choose a credentials key (e.g., `KID3`)
2. Store credentials in fnox:
   ```bash
   fnox set RENAISSANCE_KID3_USERNAME "username" --provider keychain --global
   fnox set RENAISSANCE_KID3_PASSWORD "password" --provider keychain --global
   ```
3. Add them to the `students` array in config.json with `name` and `credentials_key`
4. Run `renaissance login <name>` — the first login will authenticate and cache the session
5. To find their `user_id`: check `~/.config/renaissance/tokens-<name>.json` after login, or it comes from the gateway auth response (`identity.rgpRosterId`)

## Config Fields

| Field | Description | How to find |
|-------|-------------|-------------|
| `school_id` | School UUID in Renaissance | From marking period API calls |
| `realm_id` | School district realm UUID | From login.renaissance.com redirect URL |
| `rpid` | School's Renaissance ID | Search at schools.renaissance.com, click school, check `/organizations/{id}` API response for `loginUrl` |
| `client_id` | School's CRM ID | From gateway auth response `identity.crmId` |
| `students[].name` | Display name for CLI filter | Your choice |
| `students[].credentials_key` | Key prefix for env vars (e.g., `KID1` → `RENAISSANCE_KID1_USERNAME`) | Your choice |
| `students[].user_id` | Student's roster GUID | From gateway auth `identity.rgpRosterId` |

## Credential Format

Environment variables are keyed by `credentials_key` from config.json:

| `credentials_key` | Username env var | Password env var |
|-------------------|-----------------|-----------------|
| `KID1` | `RENAISSANCE_KID1_USERNAME` | `RENAISSANCE_KID1_PASSWORD` |
| `KID2` | `RENAISSANCE_KID2_USERNAME` | `RENAISSANCE_KID2_PASSWORD` |

## Per-student files

Each student gets their own session files in `~/.config/renaissance/`:
- `cookies-allie.txt` — curl cookie jar
- `tokens-allie.json` — cached user_id/clientId

## Known Values

- **School:** Chisholm Elementary School, Enid, OK
- **RPID:** `CPS-88RB`
- **Base URL:** `https://global-zone05.renaissance-go.com`
