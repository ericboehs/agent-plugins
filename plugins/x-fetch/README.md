# x-fetch

Retrieve the full content of an X/Twitter link. `WebFetch` returns `HTTP 402` on
every x.com URL, so this plugin routes around it in three tiers.

## Installation

```bash
claude plugin install x-fetch --marketplace ericboehs/agent-plugins
```

## Usage

- `/x-fetch <url>` — read a tweet, its images, and its article if it has one
- Or just paste an x.com link and ask what it says

## How it works

| Tier | Method | Gets you |
|---|---|---|
| 1 | `api.fxtwitter.com/<user>/status/<id>` | Tweet text, author, timestamp, expanded links, article title |
| 2 | `pbs.twimg.com/media/<id>.jpg?name=large` | Full-resolution images — where these posts usually keep the actual argument |
| 3 | `scripts/x-article.sh` → Safari AppleScript | Body text of gated `/i/article/` long-forms |

Tiers 1 and 2 need no authentication. Tier 3 drives your real Safari session, so
there is no second login and no cookie file to store — unlike the Playwright route,
which starts logged out.

## Requirements

- `curl`, `jq`
- **Tier 3 only:** Safari, signed in to X, with Develop → "Allow JavaScript from
  Apple Events" enabled (Settings → Advanced → "Show features for web developers"
  reveals the Develop menu).

Tier 3 opens a throwaway Safari window and closes it when finished; existing tabs
are left alone.
