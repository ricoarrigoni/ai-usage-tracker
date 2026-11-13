# Security

## Reporting a problem

Please don't open a public issue for security problems. Use **Report a vulnerability** on the
repository's **Security** tab instead, which sends a private report to the maintainer.

## What the app does with your data

- It reads Claude Code and Cowork logs on your Mac and stores only token counts, model, project path,
  session ID and timestamps in `~/Library/Application Support/AIUsageTracker`. Message text is never
  stored.
- It never signs in to any account and never sends your usage anywhere.
- Its only network request downloads the European Central Bank's daily exchange rates, and only when
  your Mac's currency isn't US dollars. That request carries nothing about you or your usage.

To remove everything it stored, quit the app and delete `~/Library/Application Support/AIUsageTracker`.
