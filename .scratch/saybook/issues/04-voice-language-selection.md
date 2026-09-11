# 04: Voice & language selection

**What to build:** Voice and Rate control. `--voice`, `--rate` and `--language` flags; by default the tool auto-picks the best available Voice for the Book's language (premium > enhanced > default quality). Rate is Apple's native 0–1 utterance scale, passed through unchanged.

**Blocked by:** 01 (Skeleton — one-chapter Book to playable M4B)

**Status:** ready-for-agent

- [ ] With no flags, the Voice used is the best-quality installed voice for the Book's OPF language, and the choice is visible in the progress/summary output
- [ ] `--voice <name>` accepts a voice identifier or display name as listed by `say -v ?`; an unknown name fails with exit 1 and a readable message
- [ ] `--rate` accepts 0.0–1.0 (default 0.5) and is passed straight through to the utterance; out-of-range values fail with exit 1
- [ ] `--language` overrides the Book's language for voice selection
- [ ] A language with no installed Voice fails with exit 1 and a readable error naming the language
- [ ] Changing voice or rate on the same fixture audibly changes the output (manual check)
