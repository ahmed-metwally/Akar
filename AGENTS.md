# عقارات — Agent Instructions

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Onboarding

Skills are pinned in `skills-lock.json` and deliberately not committed (`.claude/skills/` is gitignored).
After cloning, restore the exact pinned versions:

```
npx skills install
```

This gives every developer on the team the same commit of each skill. Run `npx skills update` only
by agreement, and commit the resulting `skills-lock.json` change.
