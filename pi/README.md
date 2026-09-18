# pi integration

The Claude plugins use the Agent Skills format, so pi can load their `skills/`
directories without copying or rewriting them. Configure selected directories in
`~/.pi/agent/settings.json` under `skills`.

## Code-lint extension

`extensions/code-lint.ts` adapts pi's `edit` and `write` tool results to the JSON
input expected by `plugins/code-lint/hooks/lint.sh`. The existing Claude hook and
its configuration remain the source of truth:

```text
~/.claude/code-lint/<project-hash>/config.json
```

Add the extension to pi's global settings:

```json
{
  "extensions": [
    "~/Code/github.com/ericboehs/agent-plugins/pi/extensions/code-lint.ts"
  ]
}
```

The adapter does not mark a successful edit/write as failed when lint finds an
issue. Instead, it appends the lint output to that tool result so the agent can
fix it.

## pr-review fan-out

`plugins/pr-review` needs no subagent extension. Its `fan-out.sh` spawns each
reviewer as a concurrent `pi -p` subprocess, so reviewer prompts stay out of the
calling agent's context and only the finished reports come back.

Children run with `-ne -ns -np` (no extensions, skills, or prompt templates),
which measured ~2.2K prompt tokens versus ~11.8K for a child inheriting the full
config. Context files stay enabled so reviewers can check `AGENTS.md`/`CLAUDE.md`
compliance.

Register it like any other skill directory:

```json
{
  "skills": [
    "~/Code/github.com/ericboehs/agent-plugins/plugins/pr-review/skills"
  ]
}
```
