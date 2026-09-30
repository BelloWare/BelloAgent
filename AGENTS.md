# Repository workflow

- After completing requested repository changes, commit them and push to the
  configured GitHub upstream. This is the owner's standing instruction as of
  2026-09-26; a separate request to push is not needed.
- For releases, also push the relevant release tag and any final validation-record
  commit. Follow `docs/Release.md` for packaging and website publication.
- Preserve unrelated work and existing release commit identities. Do not force-push
  or rewrite published history unless explicitly requested.
- A later request to keep work local or read-only takes precedence.

# Next release

- All work for the next release goes on the branch `dev/next`. Read
  `NEXT-RELEASE.md` first: it lists the state, what is left, and the rules.
- An agent that cannot run code commits and pushes to `dev/next` and says what
  to check; the owner's Mac runs `scripts/check-next.sh` to pull, build and test.
