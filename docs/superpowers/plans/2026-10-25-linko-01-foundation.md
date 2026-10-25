# Linko Foundation Implementation Plan (Plan 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the three private GitHub repositories with enforced rules (branching, no secrets, Conventional Commits, Claude Code guard hook), and prove on day one that a WebRTC video call between the owner's iPhone (free provisioning, CallKit) and Mac works, directly and through a TURN server on the Windows VPS.

**Architecture:** Shared tooling (guard hook, pre-commit config, PR template, ruleset JSON, bootstrap and sync scripts) is authored once in `linko-core/tooling/` and copied into the other repos by a sync script. Repos live side by side in `/Users/eugene/Mine/git/linko/`. The spike is throwaway code on an unmerged branch; its findings are recorded as ADR‑0001.

**Tech Stack:** Homebrew, mise (Tuist pin), gh CLI, git, pre-commit, gitleaks, conventional-pre-commit, Python 3 stdlib (guard hook + tests), GitHub REST API, Xcode 27, Tuist, `stasel/WebRTC` (SPM binary), CallKit, coturn.

**Spec:** `linko-apple/docs/superpowers/specs/2026-10-25-linko-design.md`

**Plan series:** 1 Foundation (this) → 2 linko-core → 3 linko-server, 4 linko-apple (3 and 4 may run in parallel after 2).

## Global Constraints

- Repositories: `linko-core`, `linko-apple`, `linko-server`; GitHub, **private**, Free plan.
- Branches: `main`, `develop`; default branch `develop`; work branches `feature/LNK-<n>-<slug>`, `fix/…`, `chore/…`, `docs/…`, `spike/…`; PRs target `develop`; releases `develop → main` + tag `vX.Y.Z`.
- `main`/`develop`: PR only, green CI, linear history on `develop`, no force push, no deletion — enforced by the guard hook and by merging only with `gh pr merge` after green checks; GitHub rulesets applied where the plan allows.
- Commits: Conventional Commits; never `--no-verify`, never skip hooks.
- Secrets never committed, read or written by the agent: `.env*` (except `.env.example`), `*.pem`, `*.key`, `*.p12`, `*.p8`, `*.cer`, `*.mobileprovision`, `config.local.json`. Layers: guard hook, pre-commit gitleaks, CI gitleaks (required check).
- A private key never leaves the host it belongs to (spec §6): the TURN shared secret and any server key are created on the VPS and stay there.
- Repository text in English; chat with the owner in Russian. Repository text describes Linko as an independent product.
- CI minutes are budgeted: gitleaks on `ubuntu-latest`; macOS/Windows jobs only on pull requests (spec §8).
- Free Apple Personal Team only; bundle ID prefix `io.github.eugenehil.linko` **[proposed]**.
- Workspace path: `/Users/eugene/Mine/git/linko/` (no spaces).
- Publishing (creating GitHub repos), merging PRs and anything run on the VPS happen only after the owner confirms.

## Review Focus

1. Guard hook gets a compound or wrapped command (`cd x && git push origin main`, `bash -c "git push origin HEAD:develop"`) → must block. *(Task 2 tests `test_blocks_push_in_compound_command`, `test_blocks_wrapped_git`)*
2. Guard hook gets malformed JSON or crashes → fails closed (exit 2 with a message). *(Task 2 `test_malformed_input_fails_closed`)*
3. Over-blocking: `.env.example`, `config.example.json`, prose that mentions `.env` in a PR title → must stay allowed. *(Task 2 `test_allows_env_example`, `test_allows_prose_that_mentions_secret_names`)*
4. Bootstrap on a Free private repo where rulesets return 403 → the script must finish, print exactly which protections were not applied, and exit 0; it must never silently claim protection. *(Task 3 `test_ruleset_forbidden_is_reported`)*
5. TURN secret ends up in the spike app, a log or a repo → the app must only ever receive `username`/`credential` computed on the VPS side. *(Task 7 Step 4 verification)*

---

### Task 1: Workspace and toolchain

**Files:**
- Create: `/Users/eugene/Mine/git/linko/README.md` — one paragraph: what the folder holds, links to the three repos (workspace only, not a repository).

**Interfaces:**
- Produces: on PATH `gh` (authenticated, scopes incl. `repo`, `workflow`), `mise`, `tuist`, `cmake`, `ninja`, `clang-format`/`clang-tidy` (Homebrew `llvm`), `swiftlint`, `swiftformat`, `gitleaks`, `pre-commit`; Xcode 27 with the owner's Apple ID signed in (Personal Team).

- [ ] **Step 1: Verify toolchain** — Run: `for t in gh mise cmake ninja swiftlint swiftformat gitleaks pre-commit xcodebuild; do command -v $t >/dev/null || echo MISSING $t; done; gh auth status` → Expected: no `MISSING`; `Logged in to github.com account EugeneHil`, token scopes include `repo` and `workflow`. Install anything missing with `brew install <name>`.
- [ ] **Step 2: Owner adds the Apple ID to Xcode** (Settings → Accounts) if not present; Verify: Xcode lists a "Personal Team".

### Task 2: Claude Code guard hook (TDD)

**Files:**
- Create: `linko-core/tooling/claude/guard.py`
- Test: `linko-core/tooling/claude/test_guard.py`
- Create: `linko-core/.claude/settings.json`

**Interfaces:**
- Produces: `decide(event: dict, current_branch: str | None, branch_lookup: Callable[[str], str | None] | None = None) -> str | None` (block reason or `None`); `main() -> int` (reads PreToolUse JSON from stdin, prints `Blocked by linko guard: <reason>` to stderr and returns 2, else 0; any exception → 2).
- Constants: `PROTECTED_BRANCHES = {"main", "develop"}`; `SECRET_GLOBS = [".env", ".env.*", "*.pem", "*.key", "*.p12", "*.p8", "*.cer", "*.mobileprovision", "config.local.json"]`; `ALLOWED_NAMES = {".env.example"}`.
- Must run on the stock macOS Python 3.9 (`from __future__ import annotations`, stdlib only).

- [ ] **Step 0:** `mkdir -p /Users/eugene/Mine/git/linko/linko-core && cd $_ && git init -b develop`
- [ ] **Step 1: Write the failing tests** (`unittest`; `E = lambda tool, **inp: {"tool_name": tool, "tool_input": inp, "cwd": "/tmp"}`). The test names are the contract; each asserts block (`IsNotNone`) or allow (`IsNone`):
  - Files: `test_blocks_reading_env`, `test_blocks_editing_env_local`, `test_blocks_writing_pem`, `test_blocks_config_local`, `test_blocks_p8_and_mobileprovision` (`/r/AuthKey_ABC.p8`, `/r/dev.mobileprovision`), `test_blocks_case_variants_on_case_insensitive_fs` (`/r/.ENV`); allow `test_allows_env_example`, `test_allows_config_example`, `test_allows_normal_source`.
  - Shell secrets: `test_blocks_cat_secret_in_bash`, `test_blocks_dotfile_globs` (`cat .e*`), `test_blocks_variable_indirection` (`f=.env; cat $f`), `test_blocks_glued_redirects` (`cat<.env`), `test_blocks_command_substitution` (`echo $(cat .env)`), `test_blocks_python_open_of_secret` (`python3 -c "open('.env').read()"`), `test_still_blocks_secret_inside_interpreter_code`; allow `test_allows_secret_name_inside_commit_message` (`git commit -m "docs: explain .env handling"`), `test_allows_prose_that_mentions_secret_names` (`gh pr create --title "docs: .env.example"`), `test_allows_harmless_globs` (`ls *.swift`).
  - Git: `test_blocks_commit_on_develop`, `test_allows_commit_on_feature`, `test_blocks_plain_push_from_main`, `test_blocks_push_refspec_to_protected` (`git push origin HEAD:main`, `git push -u origin develop`, `git push origin main`), `test_blocks_plus_and_full_ref_pushes` (`+develop`, `refs/heads/main`), `test_blocks_push_head_from_protected_branch`, `test_allows_push_feature`, `test_allows_dry_run_flag_on_push` (`git push -n origin feature/LNK-1-x`), `test_blocks_force_push` (`--force`, `-f`, `--force-with-lease`), `test_blocks_no_verify`, `test_blocks_dash_n_commit` (`git commit -nm x`), `test_blocks_hooks_bypass` (`git -c core.hooksPath=/dev/null commit`), `test_blocks_dash_c_option_commit_on_protected` (`git -C ../linko-apple commit` when that repo is on `develop`, via `branch_lookup`), `test_blocks_push_in_compound_command`, `test_blocks_wrapped_git` (`bash -c`, `eval`, `sudo`, `env X=1 git …`), `test_cd_into_other_repo_uses_that_repos_branch`, `test_checkout_protected_then_commit` (`git checkout develop && git commit -m x`).
  - Self-protection: `test_blocks_editing_guard_and_settings` (Edit/Write of `tooling/claude/guard.py`, `.claude/settings.json`, `.claude/settings.local.json`), `test_blocks_shell_writes_to_guard_and_settings` (`sed -i`, `>`, `tee`, `rm`), `test_allows_reading_guard_and_running_its_tests`.
  - Robustness: `test_unrelated_tool_allowed` (Grep on `develop`), `test_malformed_input_fails_closed` (stdin `"not json"` → `main() == 2`), `test_blocks_when_run_by_the_system_python` (runs `/usr/bin/python3 -I guard.py` with a blocking event via `subprocess`, expects exit 2), `test_message_names_linko_guard` (stderr starts with `Blocked by linko guard:`).
- [ ] **Step 2: Run tests to verify they fail** — `python3 -I -B -m unittest discover -s tooling/claude -v` → Expected: ERROR (`guard` not importable).
- [ ] **Step 3: Implement `guard.py`.** Approach: newline normalization outside quotes, `shlex.shlex(posix=True, punctuation_chars="();<>|&\`")` segmentation (fallback regex split on `ValueError`), wrapper stripping (`sudo env command nohup time exec builtin` + assignments), recursion into `bash|sh|zsh|dash|ksh -c` and `eval` (max depth 4), git option parsing (`-C`, `-c`, `--git-dir`…), branch tracking across `cd`/`checkout`/`switch` within one command; prose arguments (tokens containing whitespace) of non-interpreter commands are not word-scanned, interpreter code (`python*`, `node`, `ruby`, `perl`, `php`, `deno`, `bun`, `lua`, `osascript`) is. Any internal error → block.
- [ ] **Step 4: Run tests** — same command → Expected: `OK`; also `/usr/bin/python3 -I -B -m unittest discover -s tooling/claude` → `OK`.
- [ ] **Step 5: Write `.claude/settings.json`**: `hooks.PreToolUse = [{"matcher": "Read|Edit|Write|NotebookEdit|Bash", "hooks": [{"type": "command", "command": "python3 -I \"$CLAUDE_PROJECT_DIR/tooling/claude/guard.py\" || exit 2"}]}]`; `permissions.deny` = `Read(**/<glob>)` for every `SECRET_GLOBS` entry.
- [ ] **Step 6: Stage** — `git add tooling/claude .claude` (committed in Task 4 Step 5).

### Task 3: Shared repository tooling

**Files (in `linko-core`):**
- Create: `tooling/repo/gitignore.base` — exactly the spec §6 `.gitignore` list, first line `# --- linko shared ignores`.
- Create: `tooling/repo/.pre-commit-config.yaml` — `gitleaks/gitleaks` (`gitleaks`), `compilerla/conventional-pre-commit` (stage `commit-msg`), `pre-commit/pre-commit-hooks` (`check-merge-conflict`, `end-of-file-fixer`, `trailing-whitespace`, `check-added-large-files`); revs pinned to the latest tags at creation.
- Create: `tooling/repo/.gitleaks.toml` — `[extend] useDefault = true`; no path allowlist.
- Create: `tooling/repo/pull_request_template.md` — Summary, Linked task (`LNK-<n>`), Tests added/changed, Checklist (TDD followed, no secrets, docs/ADR updated, ran local CI script).
- Create: `tooling/repo/CLAUDE.base.md` — rules: TDD; branches/PRs; Conventional Commits; no `--no-verify`/force push; secret list (above); no new dependency without an ADR; Swift Concurrency only (spec §7 wording, including the "boundary adapter" clause for synchronous Apple APIs); no force unwraps / `try!`; warnings are errors; never log tokens, invite codes, SDP or ICE credentials; docs in English; guard hook section with its test command. Repo-specific stack/commands are appended by Plans 2–4.
- Create: `tooling/github/ruleset-develop.json` (name `protected-develop`: `deletion`, `non_fast_forward`, `required_linear_history`, `pull_request` with `allowed_merge_methods: ["squash"]`, `required_status_checks` strict with context `gitleaks`) and `tooling/github/ruleset-main.json` (name `protected-main`: same without linear history, merge methods `["merge"]`).
- Create: `tooling/github/with_checks.py` + `tooling/github/test_with_checks.py` — `with_checks(ruleset: dict, checks: list[str]) -> dict` appends extra required check contexts without duplicates, order preserved.
- Create: `tooling/github/workflows/gitleaks.yml` — job id `gitleaks`, `runs-on: ubuntu-latest`, on `pull_request` and `push`, checkout `fetch-depth: 0`, download a pinned gitleaks release tarball **and verify its SHA-256** before running `gitleaks git --config .gitleaks.toml --redact`.
- Create: `tooling/github/dependabot.yml` — `github-actions` weekly.
- Create: `tooling/sync-shared.sh <target-repo-dir>` — copies `tooling/claude/`, `.claude/settings.json`, pre-commit and gitleaks configs, PR template, workflow, dependabot (if absent); appends `gitignore.base` if its marker is absent; creates `CLAUDE.md` from the base if absent. Idempotent.
- Create: `tooling/github/bootstrap-repo.sh <name> "<description>" [check …]` — `gh repo create EugeneHil/<name> --private …` (or reuse), push `develop` and `main` only if missing on the remote, `gh repo edit --default-branch develop --delete-branch-on-merge --enable-squash-merge --enable-merge-commit --enable-rebase-merge=false`; then try to upsert both rulesets (via `with_checks.py`). If the rulesets API answers 403/404 (plan does not allow it), print `rulesets NOT applied (GitHub plan): branch rules are enforced locally by the guard hook` and continue. Does not attempt secret scanning on private repos; prints `secret scanning: not available for private repos on Free`. Ends with a summary of applied/not-applied protections.
- Create: `tooling/github/test_bootstrap.py` — runs `bootstrap-repo.sh` with a fake `gh` on `PATH` (a Python stub that logs calls and answers rulesets calls with 403).
- Create: `tooling/README.md` — what each file does, how to sync and bootstrap.

**Interfaces:**
- Consumes: Task 2 files.
- Produces: `sync-shared.sh`, `bootstrap-repo.sh` used in Task 4; check context name `gitleaks`.

- [ ] **Step 1: Failing tests** — `test_with_checks.py`: `test_appends_new_checks`, `test_never_duplicates`, `test_keeps_order`, `test_leaves_other_rules_untouched`. `test_bootstrap.py`: `test_ruleset_forbidden_is_reported` (stdout contains `rulesets NOT applied`, exit 0), `test_creates_private_repo` (fake `gh` log contains `repo create EugeneHil/x --private`), `test_skips_push_of_existing_branches`.
- [ ] **Step 2: Run** — `python3 -I -B -m unittest discover -s tooling/github -v` → Expected: FAIL/ERROR.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** — same command → `OK`; `bash -n tooling/*.sh tooling/github/*.sh` → no output.
- [ ] **Step 5: Stage** — `git add tooling .gitignore` (committed in Task 4).

### Task 4: Create the three repositories

**Files:**
- Create: `linko-core/README.md`, `linko-server/README.md`, `linko-apple/README.md` — name, one-line purpose, link to the spec in `linko-apple`.
- Create: `linko-apple/docs/adr/0000-record-architecture-decisions.md` (Context / Decision / Consequences template).
- Keep: the spec and this plan already in `linko-apple/docs/superpowers/`.

**Interfaces:**
- Produces: private repos `github.com/EugeneHil/linko-{core,apple,server}` with `develop` (default) and `main`; clones in `/Users/eugene/Mine/git/linko/`.

- [ ] **Step 1:** `git init -b develop` in `linko-apple` and `linko-server`; write the READMEs and ADR-0000; `linko-core/.gitignore` from the base.
- [ ] **Step 2:** `tooling/sync-shared.sh ../linko-apple` and `../linko-server`; run again → Expected: `git status` unchanged in both targets.
- [ ] **Step 3:** Run the workspace hygiene check `/Users/eugene/Mine/git/linko/hygiene.sh` (lives outside the repositories) → Expected: `clean`.
- [ ] **Step 4:** In each repo: `pre-commit install --hook-type pre-commit --hook-type commit-msg`; `pre-commit run --all-files` → all `Passed`.
- [ ] **Step 5: Owner** runs the bootstrap commit in each repo (the guard blocks the agent on `develop`): `! cd /Users/eugene/Mine/git/linko/<repo> && git add -A && git commit -m "chore: bootstrap repository" && git branch main`.
- [ ] **Step 6:** After the owner confirms publishing, run `../linko-core/tooling/github/bootstrap-repo.sh <repo> "<description>"` for each repo → Expected: summary lists the default branch set and states for rulesets either `applied` or `NOT applied`.
- [ ] **Step 7: Verify** — `gh repo view EugeneHil/linko-core --json visibility,defaultBranchRef -q '.visibility+" "+.defaultBranchRef.name'` → `PRIVATE develop` (same for the other two).

### Task 5: Prove the secret guards end-to-end

**Files:** none committed except the doc in Step 5.

- [ ] **Step 1: Guard layer** — ask the agent (yourself) to `Read` a file named `leak.pem` → Expected: blocked with `Blocked by linko guard:`.
- [ ] **Step 2: Local layer** — in `linko-core` on `chore/LNK-2-secret-check`: create `leak.txt` with `AKIA` + 16 uppercase characters; commit → Expected: gitleaks hook fails, commit aborted.
- [ ] **Step 3: Commit-msg layer** — commit a harmless file with message `wip stuff` → Expected: conventional-pre-commit fails.
- [ ] **Step 4: CI layer** — the **owner** commits `leak.txt` with hooks bypassed (`! git -c core.hooksPath=/dev/null commit -m "test: ci leak"`), pushes the branch, opens a PR to `develop` → Expected: `gitleaks` check fails. Close the PR, delete the remote and local branch.
- [ ] **Step 5:** Record the outcomes (and that GitHub push protection is unavailable on private Free repos) in `linko-core/tooling/README.md`, section "Secret guards — verified", via PR `docs/LNK-2-secret-guards` → `develop`.

### Task 6: Spike A — WebRTC call iPhone ↔ Mac on the LAN with CallKit (throwaway)

Spike rules: no tests, not merged; branch `spike/LNK-3-webrtc-callkit` in `linko-apple`; only ADR-0001 is merged.

**Files (spike branch):**
- `Spike/Project.swift` — Tuist: targets `SpikeiOS` (iOS 18) and `SpikeMac` (macOS 15), SPM dependency `https://github.com/stasel/WebRTC.git` pinned to an **exact** version (record version and checksum), bundle IDs `io.github.eugenehil.linko.spike` / `…spike.mac`.
- `Spike/Shared/` — `PeerSession` (RTCPeerConnectionFactory, camera capture, audio + video tracks, one data channel `"ctl"`), JSON signaling messages `offer|answer|ice|hangup`.
- `Spike/Mac/` — `NWListener` WebSocket relay on port 9000 + the Mac call UI (caller).
- `Spike/iOS/` — WebSocket client to `ws://<mac-lan-ip>:9000`, CallKit `CXProvider` reporting the incoming call, `RTCAudioSession.useManualAudio = true` and `isAudioEnabled` toggled in `provider(_:didActivate:)` / `didDeactivate`.
- Info.plist keys: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`; background modes `audio` (+ try `voip`, see Step 3).

- [ ] **Step 1:** Build and run `SpikeMac`; build `SpikeiOS` to the owner's iPhone with the Personal Team (owner trusts the developer profile in Settings → General → VPN & Device Management).
- [ ] **Step 2: Verify** — the Mac calls → the iPhone (app in foreground) shows the CallKit incoming UI → answer → two-way video and audio; the `ctl` data channel echoes a test message; hangup on either side ends both; afterwards the iPhone microphone indicator turns off.
- [ ] **Step 3: Record** — whether declaring the `voip` background mode breaks installation with free provisioning; whether CallKit UI appears when the app was backgrounded < 30 s; the WebRTC version/checksum; the app binary size; any `AVAudioSession` errors in the console.

### Task 7: Spike B — TURN on the Windows VPS and a call over cellular (throwaway)

**Files:**
- Spike branch: `Spike/turn/turn-cred.py` — prints `username`/`credential` for the REST scheme (`username = f"{int(time.time()) + 3600}:spike"`, `credential = base64(hmac_sha1(secret, username))`); reads the secret from the environment variable `LINKO_TURN_SECRET`; runs **on the VPS only**.
- Spike branch: `Spike/relay/relay.py` — throwaway WebSocket relay for the cellular test, run on the VPS in a venv (`websockets` package), port 9000.
- Merged (Task 8): `linko-apple/docs/turn-setup.md` — the exact VPS steps that worked.

- [ ] **Step 1 (owner confirms each VPS action):** build coturn natively with MSVC via its CMake + vcpkg (`libevent`, `openssl`, `pthreads`); if that fails within ~1 h, install it in WSL2 instead. Config on the VPS only: `use-auth-secret`, `static-auth-secret=<generated on the VPS with a CSPRNG, 32+ bytes>`, `realm=linko`, `listening-port=3478`, `min-port=49160`, `max-port=49200`, `no-tls`, `no-cli`, `fingerprint`. Firewall: allow UDP/TCP 3478 and UDP 49160–49200.
- [ ] **Step 2: Verify TURN** — from the Mac: `turnutils_uclient -u <username> -w <credential> -y <vps-ip>` (Homebrew `coturn` provides the client) → Expected: allocations succeed, 0 % loss.
- [ ] **Step 3: Verify the call** — point the spike apps at `ws://<vps-ip>:9000` and the TURN URL with credentials pasted from `turn-cred.py`; iPhone on LTE (Wi‑Fi off), Mac on home Wi‑Fi; set `iceTransportPolicy = .relay` for one run → Expected: call connects; `getStats` shows a `relay` candidate pair; note RTT and bitrate. Repeat with `.all` and note the selected pair type.
- [ ] **Step 4: Verify secret hygiene** (Review Focus 5) — `grep -rn "static-auth-secret\|LINKO_TURN_SECRET=" /Users/eugene/Mine/git/linko` → no secret value anywhere on the Mac; the spike apps contain only pasted short-lived credentials; the relay and coturn are stopped and the relay port 9000 is closed in the firewall after the spike (coturn may stay as a service with the firewall rules if the owner agrees).
- [ ] **Step 5: Record** — which TURN build path worked, Windows Server version, which ports are free (443 for the future server?), measured RTT/bitrate over relay, anything that blocked.

### Task 8: ADR-0001 and handoff

**Files:**
- Create: `linko-apple/docs/adr/0001-webrtc-callkit-turn-spike.md` — Context, Decision, Findings (Tasks 6–7 records), exact configuration that worked, not verified, consequences for Plans 2–4.
- Create: `linko-apple/docs/turn-setup.md` — runbook from Task 7.

- [ ] **Step 1:** Write both documents from the recorded findings; no secrets, IP addresses replaced by `<vps-ip>`.
- [ ] **Step 2:** `/Users/eugene/Mine/git/linko/hygiene.sh` → `clean`; `pre-commit run --all-files` → `Passed`.
- [ ] **Step 3:** Push the spike branch (not merged). PR `docs: ADR-0001 WebRTC, CallKit and TURN spike` from `docs/LNK-4-adr-0001` → `develop`; merge only after the owner approves.

---

## Self-review notes
- Spec §5 (repos, branches, protection, Conventional Commits, PR template), §6 (secret layers, key custody, `.gitignore`), §3 (free provisioning, private Free repos, TURN), §7 (CLAUDE.md, ADRs, Swift Concurrency rule), §8 (CI budget: gitleaks on Linux, Dependabot), §9 item 1 (day-one spike incl. TURN) — covered. CODEOWNERS is omitted: one owner, zero required reviews **[proposed]**.
- Repo-specific CI (build/test/coverage/lint jobs), `scripts/ci-local.sh`, and CLAUDE.md stack sections belong to Plans 2–4.
