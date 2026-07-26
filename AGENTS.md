# Work Bench repository instructions

## Privacy and pre-push gate

Treat privacy validation as a required release check. Before every push, inspect
the complete staged diff, every new commit, and all newly tracked files for
personal information, credentials, and machine-specific configuration.

- Never commit a person's name, personal email, phone number, account name,
  home-directory path, precise location, notification content, device serial,
  hardware MAC, advertising identifier, Wi-Fi name, private hostname, or
  private IP address.
- Never commit passwords, tokens, API keys, private certificates, signing
  material, service-account files, unredacted device logs, screenshots, audio
  captures, or protocol traces containing real identifiers.
- Documentation, tests, fixtures, command examples, and reports use explicit
  generic values such as `<android-serial>`, `<g2-serial>`, `<user-home>`,
  `developer@example.invalid`, and clearly synthetic MAC addresses.
- Keep protocol constants and required third-party copyright notices intact.
  They are not personal configuration.
- Use the repository-safe commit identity
  `Work Bench Contributors <noreply@workbench.invalid>`. Review the author and
  committer fields of every outgoing commit.
- If a check finds a personal value, stop the push, remove it from code and
  history as needed, replace examples with generic placeholders, and rerun the
  complete gate. Adding a file to `.gitignore` does not remove it from an
  existing commit.

At minimum, run and review these checks before pushing:

```sh
git status --short
git diff --check
git diff --cached --check
git diff --cached
git log --format='%h %an <%ae> | %cn <%ce>' origin/main..HEAD
git grep -I -n -E '(/home/[^/[:space:]]+|/Users/[^/[:space:]]+|/mnt/[^/[:space:]]+|[A-Za-z]:\\Users\\)'
git grep -I -n -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
git grep -I -n -i -E '(password|passwd|api[_-]?key|client[_-]?secret|access[_-]?token|private[_-]?key)'
```

The searches intentionally over-report. Review each match, including binary
metadata and newly generated evidence, and only proceed when every retained
value is demonstrably generic or public.

## Screenshot handling

Treat raw screenshots and screen recordings as temporary, sensitive test
evidence. They must never be created, copied, or retained anywhere inside this
repository, including in an ignored working-tree directory.

- Before capturing, create a fresh directory outside the repository with
  `mktemp -d "${TMPDIR:-/tmp}/workbench-screenshots.XXXXXX"` and send every
  capture directly to that absolute path.
- Inspect raw captures only from that temporary directory. Never stage, commit,
  attach, or push a raw capture, even if the visible screen appears generic.
- A sanitized documentation derivative may enter `docs/images/` only when the
  user explicitly requests it. Create the derivative from the temporary source,
  remove or replace every device, account, notification, transcript, location,
  and free-form user value with generic demonstration content, then visually
  inspect it before staging. Never copy the raw source into the repository.
- Delete the temporary capture directory as soon as validation is complete.
- Before every push, review newly added image and video files with
  `git diff --cached --name-only --diff-filter=A` and stop if any are test
  captures or unreviewed derivatives. Repository-owned artwork is allowed only
  after confirming that it contains no personal or device-specific data.

## UI/UX source of truth

Always follow the inline **UI/UX examples** section on the Tools page and the
tokens in `lib/src/ui/workbench_theme.dart` for every UI or UX change.

- Use the demonstrated hierarchy: `titleMedium` for page sections,
  `titleSmall` for subsection titles, `bodyMedium` for primary copy, and
  `bodySmall` for compact status and supporting text.
- Use 16dp section padding, 12dp between groups, and 8dp between related
  controls. Every interactive target must remain at least 48dp.
- Use one filled button for the primary action, outlined buttons for secondary
  actions, and tonal buttons only for advanced tools. Button labels begin with
  a clear verb.
- Keep the interface grayscale. Green is reserved for connected or actively
  streaming status dots, and every colored state must also have a text label.
- Prefer one compact column, short labels, and one-line live status. Do not add
  nested scrolling, duplicate status, decorative cards, or a new interaction
  just to reveal guidance that can be shown inline.
- Logs and raw protocol data may use monospace; normal UI text uses the
  platform sans-serif font.

If a UI change introduces a genuinely new reusable pattern, update the inline
Tools-page examples in the same change. Before finishing UI work, run
`flutter analyze`, `flutter test`, and inspect the result on a representative
phone-sized viewport.

## Audio test source of truth

Use the checked-in
`.agents/skills/kokoro-g2-transcription-loop/SKILL.md` skill for physical G2
audio validation. The repository copy is the source of truth; keep any locally
installed copy synchronized with it.

Every acoustic run uses Kokoro `af_maple`, 90% computer volume, one second of
digital leading silence, and 500 ms of trailing silence. The runner must restore
the original speaker volume even after failure. Every run must contain explicit
`playback_start` and `playback_end` Android log markers. Calculate the quiet
baseline only from audio summaries before `playback_start`; ignore stale VAD
and transcript markers before it.

Use a fresh output directory for every trial. Preserve the WAV, SHA-256
manifest, device log, and JSON report for passes and failures. Never rerun until
one trial passes and then omit earlier failures. Diagnose and report transport,
activity, VAD, STT, and safety boundaries independently.

Keep two test layers separate:

- Physical Kokoro replay validates speaker output, G2 capture, BLE transport,
  durable WAV persistence, VAD boundaries, queue safety, and recovery.
- STT model ranking decodes byte-for-byte copies of one saved G2 WAV. Separate
  acoustic replays are never a direct model comparison.

For model comparisons, preserve the source SHA-256 and expected text; use the
same phone, app revision, provider, thread count, and thermal starting state;
require ready/completed log markers naming the model; and report WER, decode
time, final-tail coverage, PSS/RSS/swap, thermal state, and Android
low-memory/process-kill events. Include short, 10–20 second, and longer-than-30
second captures. Never attribute VAD turn count to an STT model.

Before accepting physical evidence, run both checked-in skill test files. A
transcript alone is never a pass: playback boundaries, frame rate, activity
rise, VAD/queue ordering, transcript threshold, disconnect safety, capture
safety, and worker recovery must all satisfy the case contract.
