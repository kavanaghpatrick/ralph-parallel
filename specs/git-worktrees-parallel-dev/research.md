---
spec: git-worktrees-parallel-dev
phase: research
created: 2026-02-21
updated: 2026-02-21
---

# Research: Parallel AI Agent Workflows with Git Worktrees

## Executive Summary

Git worktrees have become the standard isolation mechanism for running multiple AI coding agents in parallel on a single codebase, with adoption by all major platforms (Claude Code, Cursor, OpenAI Codex, Cline). The technique enables 3-16+ simultaneous agents working on independent branches while sharing a single `.git` directory. Key challenges remain around merge conflict detection/resolution, coordination overhead, and quality control -- but new tooling (Clash, ccswarm, Claude Code Agent Teams) is rapidly addressing these gaps.

> **Deep Technical Addendum (2026-02-21)**: See [Appendix: Git Internals Deep Dive](#appendix-git-internals-deep-dive) at the end of this document for detailed analysis of git worktree internals, concurrency safety, locking mechanisms, merge strategies, conflict detection, shared resources, and performance considerations.

## External Research

### 1. Git Worktrees: How They Work

Git worktrees create linked working directories sharing a single `.git` object database. Each worktree maintains its own HEAD, staging area, and working files through a `.git` file pointing to `gitdir: /path/main/.git/worktrees/[name]`.

**Core commands:**
```bash
git worktree add -b feature-auth ../auth-work main   # Create with new branch
git worktree add ../project-bugfix bugfix-123         # Use existing branch
git worktree list                                      # View all
git worktree remove ../auth-work                       # Cleanup
git worktree prune                                     # Clean stale metadata
```

**Key advantages over cloning:**
- One `git fetch` updates all worktrees simultaneously
- Avoids 5x disk overhead of full clones (500MB repo x 5 clones = 2.5GB vs shared objects)
- All branches in sync through shared history

**Source:** [Nx Blog - Git Worktrees AI Agents](https://nx.dev/blog/git-worktrees-ai-agents), [Upsun Developer Center](https://devcenter.upsun.com/posts/git-worktrees-for-parallel-ai-coding-agents/)

### 2. Best Practices for Parallel Agent Work

| Practice | Details | Source |
|----------|---------|--------|
| Centralized directory | Use `.trees/` or `.claude/worktrees/` for all worktrees | [Nick Mitchinson](https://www.nrmitchi.com/2025/10/using-git-worktrees-for-multi-feature-development-with-ai-agents/) |
| One task per worktree | Each worktree gets a single focused task/spec | [motlin.com](https://motlin.com/blog/claude-code-worktree) |
| Regular rebasing | Rebase often to prevent drift from main | [git worktree best practices](https://gist.github.com/induratized/49cdedac) |
| Agent boundaries | Specify safe operations: commits, local branches, pulls; prohibit force pushes, cross-branch mods | [Nick Mitchinson](https://www.nrmitchi.com/2025/10/using-git-worktrees-for-multi-feature-development-with-ai-agents/) |
| File ownership | Break work so each agent owns different files; avoid two agents editing the same file | [Claude Code Agent Teams docs](https://code.claude.com/docs/en/agent-teams) |
| Cleanup after | Always `git worktree remove` + `git worktree prune` after merge | [Upsun](https://devcenter.upsun.com/posts/git-worktrees-for-parallel-ai-coding-agents/) |
| Add to .gitignore | `.claude/worktrees/` should be in `.gitignore` | [Claude Code docs](https://code.claude.com/docs/en/common-workflows) |

### 3. Multi-Agent Coordination Patterns

#### A. Claude Code Native Approaches

**Task Tool (Subagents):**
- Spawns ephemeral workers with independent 200k context windows
- Up to 10 tasks in parallel, processed in batches
- Workers report results back to parent; no inter-worker communication
- Best for focused, independent subtasks

**Agent Teams (Experimental):**
- Full independent Claude Code sessions with shared task lists and messaging
- Team lead coordinates, spawns teammates, assigns work
- Teammates can message each other directly (unlike subagents)
- Each teammate gets its own worktree for file isolation
- Task claiming uses file locking to prevent race conditions
- Supports plan approval gates (teammate plans in read-only mode, lead approves)
- Hooks: `TeammateIdle` and `TaskCompleted` for quality enforcement

**`--worktree` flag:**
- `claude --worktree feature-auth` creates isolated worktree at `.claude/worktrees/feature-auth/`
- Branch named `worktree-feature-auth`, based on default remote branch
- Auto-cleanup: no changes = auto-remove; changes = prompt user

**Source:** [Claude Code Common Workflows](https://code.claude.com/docs/en/common-workflows), [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)

#### B. External Framework Patterns

| Framework | Coordination Model | Parallel Support | Source |
|-----------|-------------------|-----------------|--------|
| **CrewAI** | Role-based agents with sequential/parallel/conditional task execution | Built-in parallel task processing | [CrewAI](https://www.crewai.com/) |
| **MetaGPT** | Simulates full team (PM, dev, QA) with structured workflows | Standardized engineering workflows | [MetaGPT GitHub](https://github.com/FoundationAgents/MetaGPT) |
| **ccswarm** | Master Claude + session manager + git worktree manager | Multi-provider agent pool (Claude, Aider, Codex) | [ccswarm GitHub](https://github.com/nwiizo/ccswarm) |
| **Cursor 2.0** | Up to 8 concurrent agents with independent workspaces | Git worktrees or remote machines | [Cursor docs](https://cursor.com/) |
| **OpenAI Codex** | Isolated cloud environments per agent | Built-in worktree support | [VentureBeat](https://venturebeat.com/orchestration/openai-launches-a-codex-desktop-app-for-macos-to-run-multiple-ai-coding) |

#### C. Anthropic's C Compiler Experiment (16 Parallel Agents)

Most impressive real-world example of parallel AI agents:
- **16 Claude agents** in Docker containers, ~2,000 sessions over 2 weeks
- **Git-based locking**: agents claimed tasks by creating files in `current_tasks/` directory
- **No orchestrator**: agents picked "the next most obvious problem" autonomously
- **Specialization via prompts**: different agents focused on performance, code quality, design critique
- **Result**: 100,000-line Rust compiler that boots Linux across x86/ARM/RISC-V
- **Cost**: ~$20K (2B input tokens, 140M output tokens)

**Key learnings:**
- Context window pollution from test output required deterministic sampling
- When all 16 agents hit the same bug, parallelism collapsed (solved via task decomposition)
- "Most effort went into designing the environment around Claude"

**Source:** [Anthropic Engineering Blog](https://www.anthropic.com/engineering/building-c-compiler)

#### D. Cursor's Three-Tier Architecture

Most effective coordination pattern found (after failed attempts with equal-status agents):
1. **Planners**: continuously explore codebase and create tasks
2. **Workers**: execute assigned tasks without coordinating with each other
3. **Judge agents**: evaluate whether to continue at each cycle end

Earlier attempts with locking mechanisms caused severe throughput degradation (20 agents slowed to 2-3). Optimistic concurrency control made agents risk-averse.

**Source:** [Mike Mason - AI Coding Agents Jan 2026](https://mikemason.ca/writing/ai-coding-agents-jan-2026/)

### 4. Conflict Detection and Resolution

#### Clash: Purpose-Built Conflict Detection

Open-source Rust CLI that detects conflicts between worktrees without modifying the repository.

**How it works:**
- Uses `git merge-tree` (via gix library) for three-way merges between worktree pairs
- 100% read-only operations
- Commands: `clash check <file>`, `clash status`, `clash watch`, `clash status --json`

**Claude Code integration (hooks):**
```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [{"type": "command", "command": "clash check"}]
    }]
  }
}
```

**Source:** [Clash GitHub](https://github.com/clash-sh/clash)

#### Grove: Cross-Worktree Conflict Intelligence

Detects file, hunk, symbol, dependency, and schema overlaps between parallel workstreams before merge time.

**Source:** [Grove GitHub](https://github.com/NathanDrake2406/grove)

#### AI-Assisted Merge Resolution

- **VS Code 1.105** (Sept 2025): AI-assisted merge conflict resolution with agentic flow
- **GitKraken**: Auto-resolve with AI provides first-pass resolutions with explanations
- **GitHub Copilot Pro+**: Complex merge conflicts resolved automatically
- **rizzler**: AI-powered merge conflict resolution tool

**Source:** [Graphite Guide](https://graphite.com/guides/ai-code-merge-conflict-resolution), [InfoWorld](https://www.infoworld.com/article/4075822/visual-studio-code-taps-ai-for-merge-conflict-resolution.html)

### 5. Git Merge Strategies for Parallel Branches

| Strategy | Use Case | Limitations |
|----------|----------|-------------|
| **Sequential merge** | Merge branches one at a time into main | Order matters; later merges inherit earlier changes |
| **Octopus merge** | Merge 2+ branches simultaneously in single commit | Refuses if conflicts exist; only for clean merges |
| **Rebase before merge** | Rebase each feature onto latest main before merging | Cleaner history; more manual effort |
| **PR-based** | Each worktree creates PR, reviewed/merged individually | Standard workflow; scales well |
| **Cherry-pick** | Pick specific commits from worktrees into single branch | Flexible but can lose context |
| **Continuous merge (git-octopus)** | Automated periodic merging for CI/CD | Requires conflict-free branches |

**Recommended approach for parallel agents:**
1. Each agent works on its own branch in its own worktree
2. Use `clash status` to detect conflicts early
3. Merge branches sequentially via PRs (not octopus - too brittle)
4. For conflicting branches: rebase the later branch onto the first merged branch
5. Use AI-assisted merge resolution for remaining conflicts

**Source:** [Atlassian Git Merge Strategies](https://www.atlassian.com/git/tutorials/using-branches/merge-strategy), [git-octopus](https://github.com/lesfurets/git-octopus)

### 6. Spec-Driven Development for Parallel Agents

Spec-driven development (SDD) has emerged as one of 2025's key engineering practices, providing the structured inputs needed for parallel agent work.

**Key principles:**
- Specifications as primary artifact; code as generated output
- Specs use domain-oriented language, Given/When/Then format, explicit behavior definitions
- Separate planning phase (human) from implementation phase (agent)
- Specs decomposed into atomic tasks that agents can work independently

**Tools:**
- GitHub Spec Kit: templates and CLI for SDD
- AWS Kiro: 3-phase Specify -> Plan -> Execute with AWS integration
- Claude Code planning mode: read-only analysis before implementation

**Parallel enablement:**
- Specs define clear file ownership boundaries
- Task decomposition creates independent work units
- Multiple agents can implement different specs simultaneously
- [VERIFY] gates ensure quality before merge

**Source:** [Thoughtworks SDD](https://www.thoughtworks.com/en-us/insights/blog/agile-engineering-practices/spec-driven-development-unpacking-2025-new-engineering-practices), [GitHub Spec Kit](https://github.com/github/spec-kit), [The New Stack](https://thenewstack.io/spec-driven-development-the-key-to-scalable-ai-agents/)

### 7. Real-World Production Usage

| Company/Project | Scale | Approach | Source |
|----------------|-------|----------|--------|
| Anthropic internal | 5-10 parallel sessions | 5 local on MacBook, 5-10 on website | [Mike Mason](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) |
| Anthropic C compiler | 16 agents, 2 weeks | Docker containers, git locking | [Anthropic Engineering](https://www.anthropic.com/engineering/building-c-compiler) |
| incident.io | 4-5 parallel Claude agents | Routine usage | Referenced in multiple sources |
| Cursor browser project | 1M+ lines, 1000 files | Multi-agent with worktrees | [Mike Mason](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) |
| Gas Town | 44K lines in 12 days | Multi-agent parallel | [Mike Mason](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) |
| Cisco, Ramp, Duolingo | Enterprise | OpenAI Codex parallel agents | [VentureBeat](https://venturebeat.com/orchestration/openai-launches-a-codex-desktop-app-for-macos-to-run-multiple-ai-coding) |

### Pitfalls to Avoid

| Pitfall | Details | Source |
|---------|---------|--------|
| Disk space explosion | 20min session with ~2GB codebase used 9.82GB (Cursor forum) | [Cursor forums](https://forum.cursor.com/) |
| Quality degradation | Google DORA 2025: 90% AI adoption = 9% more bugs, 91% longer reviews, 154% larger PRs | [Mike Mason](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) |
| Perception gap | METR study: devs 19% slower with AI but believed 20% faster (39-point gap) | [Mike Mason](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) |
| Context window pollution | Test output flooding agent context | [Anthropic Engineering](https://www.anthropic.com/engineering/building-c-compiler) |
| Parallelism collapse | All agents hitting same blocker simultaneously | [Anthropic Engineering](https://www.anthropic.com/engineering/building-c-compiler) |
| Locking degradation | 20 agents with locks slowed to 2-3 effective | [Mike Mason](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) |
| Blind overwrites | Two agents editing same file = lost work | [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams) |
| Rate limiting | Too many parallel agents = API rate limits | [motlin.com](https://motlin.com/blog/claude-code-worktree) |
| Env setup per worktree | Each worktree needs `npm install`, env vars, etc. | [Claude Code docs](https://code.claude.com/docs/en/common-workflows) |

## Codebase Analysis

This is a greenfield research project (`/Users/patrickkavanagh/parallel_ralph/`) with no existing codebase to analyze. The specs directory structure suggests a spec-driven development approach is being established.

### Existing Patterns
- Spec directory at `/Users/patrickkavanagh/parallel_ralph/specs/git-worktrees-parallel-dev/`
- No existing code, configuration, or dependencies

### Dependencies
- Git (for worktree support)
- Claude Code CLI (for `--worktree` flag and agent teams)
- Optional: tmux or iTerm2 (for split-pane agent teams)
- Optional: Clash (for conflict detection)

### Constraints
- Git worktrees require a git repository (this project is not yet a git repo)
- Claude Code Agent Teams are experimental (require `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- Each worktree needs independent environment setup
- API rate limits constrain max parallel agents

## Feasibility Assessment

| Aspect | Assessment | Notes |
|--------|------------|-------|
| Technical Viability | **High** | Git worktrees + Claude Code --worktree is mature, well-documented |
| Effort Estimate | **M** (Medium) | Setup is straightforward; coordination patterns need design |
| Risk Level | **Medium** | Merge conflicts and quality control are known challenges with emerging tooling |

## Recommendations for Requirements

1. **Use git worktrees as the isolation mechanism** -- it is the industry standard for parallel AI agent work, supported natively by Claude Code, Cursor, and Codex
2. **Design tasks for file-level independence** -- the single most effective conflict prevention strategy is ensuring parallel agents own different files
3. **Implement Clash hooks** for early conflict detection rather than discovering conflicts at merge time
4. **Use sequential PR-based merging** (not octopus merge) for reliability -- octopus merge fails on any conflict
5. **Start with 3-5 parallel agents** -- Anthropic's own recommendation; scaling to 16 is possible but requires careful environment design
6. **Adopt spec-driven development** -- specs provide the structured, atomic task definitions needed for effective parallel work
7. **Consider Claude Code Agent Teams** for tasks requiring inter-agent communication; use subagents/worktrees for independent tasks
8. **Budget for environment setup time** per worktree (`npm install`, env vars, etc.)
9. **Implement quality gates** -- hooks, CI checks, and test requirements before merge to counter the quality degradation trend
10. **Use `motlin.com` pattern for task management** -- separate `.llm/todo.md` per worktree with a single focused task

## Open Questions

- What is the target codebase size? Affects disk space planning for worktrees
- Will agents need to communicate during execution, or are tasks fully independent?
- What CI/CD pipeline exists? Needed for quality gate design
- Is there a preference for Claude Code Agent Teams vs manual worktree orchestration?
- What's the acceptable cost budget per parallel development session?
- Should failed/conflicting implementations be discarded or AI-resolved?

## Sources

### Official Documentation
- [Claude Code Common Workflows](https://code.claude.com/docs/en/common-workflows)
- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [Git Worktree Documentation](https://git-scm.com/docs/git-worktree)

### In-Depth Articles
- [Nx Blog: How Git Worktrees Changed My AI Agent Workflow](https://nx.dev/blog/git-worktrees-ai-agents)
- [Nick Mitchinson: Using Git Worktrees for Multi-Feature Development with AI Agents](https://www.nrmitchi.com/2025/10/using-git-worktrees-for-multi-feature-development-with-ai-agents/)
- [motlin.com: Claude Code /worktree](https://motlin.com/blog/claude-code-worktree)
- [Agent Interviews: Parallel AI Coding with Git Worktrees](https://docs.agentinterviews.com/blog/parallel-ai-coding-with-gitworktrees/)
- [Upsun: Git worktrees for parallel AI coding agents](https://devcenter.upsun.com/posts/git-worktrees-for-parallel-ai-coding-agents/)
- [Tessl: How to Parallelize AI Coding Agents](https://tessl.io/blog/how-to-parallelize-ai-coding-agents/)

### Analysis & Opinion
- [Mike Mason: AI Coding Agents in 2026: Coherence Through Orchestration](https://mikemason.ca/writing/ai-coding-agents-jan-2026/)
- [Thoughtworks: Spec-Driven Development](https://www.thoughtworks.com/en-us/insights/blog/agile-engineering-practices/spec-driven-development-unpacking-2025-new-engineering-practices)
- [Anthropic Engineering: Building a C Compiler with 16 Agents](https://www.anthropic.com/engineering/building-c-compiler)

### Tools
- [Clash: Merge conflict detection across worktrees](https://github.com/clash-sh/clash)
- [ccswarm: Multi-agent orchestration for Claude Code](https://github.com/nwiizo/ccswarm)
- [Grove: Cross-worktree conflict intelligence](https://github.com/NathanDrake2406/grove)
- [GitHub Spec Kit](https://github.com/github/spec-kit)
- [Parallel Worktrees Skill for Claude Code](https://github.com/spillwavesolutions/parallel-worktrees)

### Industry Reports
- [Medium: Git Worktrees - Secret Weapon for Parallel AI Agents](https://medium.com/@mabd.dev/git-worktrees-the-secret-weapon-for-running-multiple-ai-coding-agents-in-parallel-e9046451eb96)
- [Atlassian: Git Merge Strategy Options](https://www.atlassian.com/git/tutorials/using-branches/merge-strategy)
- [VentureBeat: OpenAI Codex Desktop App](https://venturebeat.com/orchestration/openai-launches-a-codex-desktop-app-for-macos-to-run-multiple-ai-coding)

---

# Appendix: Git Internals Deep Dive

*Added 2026-02-21. Deep technical analysis of git worktree internals, concurrency safety, and operational strategies for parallel automated development.*

## A1. Git Worktree Internal Architecture

### Directory Structure

```
repo/.git/                          # Main worktree's GIT_DIR (the "common dir")
  |-- objects/                      # SHARED: single object database
  |-- refs/heads/                   # SHARED: branch refs
  |-- refs/tags/                    # SHARED: tag refs
  |-- refs/bisect/                  # PER-WORKTREE (exception)
  |-- refs/worktree/                # PER-WORKTREE (exception)
  |-- refs/rewritten/               # PER-WORKTREE (exception)
  |-- config                        # SHARED config
  |-- worktrees/
       |-- wt-1/
       |    |-- HEAD                # PER-WORKTREE: each worktree tracks own HEAD
       |    |-- index               # PER-WORKTREE: each has own staging area
       |    |-- gitdir              # Points back to worktree path on disk
       |    |-- locked              # Optional lock file (plain text reason)
       |    |-- config.worktree     # PER-WORKTREE config (if extensions.worktreeConfig=true)
       |    |-- MERGE_HEAD          # PER-WORKTREE
       |    |-- REBASE_HEAD         # PER-WORKTREE
       |-- wt-2/
            |-- ...

repo-wt-1/                         # Linked worktree directory on disk
  |-- .git                          # FILE (not dir!), contains: "gitdir: /path/to/repo/.git/worktrees/wt-1"
  |-- <working files>
```

**Key environment variables in a linked worktree**:
- `$GIT_DIR` = `/path/to/repo/.git/worktrees/wt-1` (private subdirectory)
- `$GIT_COMMON_DIR` = `/path/to/repo/.git` (shared common directory)
- Path resolution via `git rev-parse --git-path` automatically routes to the correct location

### Shared vs Isolated Resources Matrix

| Resource | Shared/Isolated | Concurrency Implication |
|----------|----------------|------------------------|
| Object database (`objects/`) | **Shared** | Content-addressed writes are idempotent -- safe |
| Pack files | **Shared** | gc/repack affects all worktrees -- DANGEROUS |
| Branch refs (`refs/heads/`) | **Shared** | Per-ref lock files; different branches safe |
| Tag refs (`refs/tags/`) | **Shared** | Per-ref lock files |
| HEAD | **Isolated** | No contention between worktrees |
| Index (staging area) | **Isolated** | Independent `git add`/`git reset` per worktree |
| Working directory | **Isolated** | Full filesystem separation |
| `refs/bisect/` | **Isolated** | Per-worktree bisect sessions |
| `refs/worktree/` | **Isolated** | Private ref namespace per worktree |
| Config (with `worktreeConfig`) | **Isolated** | Per-worktree settings possible |
| Hooks | **Shared** | Same hooks execute in all worktrees |
| `.gitignore` / `.gitattributes` | **Shared** | Part of tracked content |
| `index.lock` | **Isolated** | Each worktree has its own lock file |

### Branch Exclusivity Enforcement

A branch **cannot** be checked out in more than one worktree simultaneously. This prevents ambiguity about which worktree's operations update the branch ref.

```bash
# FAILS if branch "feature-x" is already checked out in another worktree
git worktree add ../wt-new feature-x
# fatal: 'feature-x' is already checked out at '/path/to/other-worktree'

# Workarounds:
git worktree add -d ../wt-new HEAD           # Detached HEAD
git worktree add -b new-name ../wt-new main  # New branch from base
```

**Source**: [git-scm.com/docs/git-worktree](https://git-scm.com/docs/git-worktree)

---

## A2. Concurrent Git Operations: Safety Analysis

### Operations Safe to Run in Parallel Across Worktrees

| Operation | Why Safe |
|-----------|----------|
| `git add` / `git reset` | Uses worktree-private index file (`worktrees/wt-1/index`) |
| `git status` | Reads worktree-private index + working dir only |
| `git diff` (unstaged) | Compares working dir vs private index |
| `git stash` | Per-worktree operation |
| `git commit` | Private index -> shared objects (content-addressed, idempotent) -> per-branch ref lock |
| `git branch -b` (different names) | Per-ref lock files; no contention if names differ |
| File editing | Completely isolated working directories |

### Operations with Contention Risk

| Operation | Shared Resource | Lock Mechanism | Risk Level |
|-----------|----------------|----------------|------------|
| `git commit` | Object DB + `refs/heads/<branch>` | `index.lock` (per-wt) + `<ref>.lock` | **Low**: separate branches don't contend |
| `git fetch` | `objects/` + `refs/remotes/` | Object writes safe; remote ref locks | **Low-Medium**: parallel fetches may contend on same remote refs |
| `git gc` / `git repack` | `objects/` pack files | Object DB lock | **HIGH**: can delete objects another worktree is using |
| `git push` | Remote refs | Network-level CAS | **Low**: push is atomic per-ref on remote |
| `git merge` (into branch) | Ref update | `<ref>.lock` for target | **Low**: each worktree merges into different branch |

### Object Database Write Mechanism (Why Concurrent Object Creation Is Safe)

Git loose objects use a **write-to-temp-then-atomic-rename** strategy:

1. Write object data to temporary file in `objects/` with random name
2. `fsync()` the data (if `core.fsync` enabled, recommended for durability)
3. Atomic `rename()` to final content-addressed path (`objects/ab/cdef1234...`)

Because objects are **content-addressed**, two processes writing the same object simultaneously produce the same filename with the same content -- the rename is **idempotent**. This is the fundamental reason concurrent object creation is inherently safe.

**Caveat**: If an object with the target hash already exists, Git silently drops the new data without verifying content matches the hash. Only `git fsck` can detect this (extremely rare) corruption.

**Source**: [git-scm.com/docs/git-config (core.fsync)](https://git-scm.com/docs/git-config/2.36.0), [kernel.org fsync patches](https://lore.kernel.org/git/f1e8a7bb3bf0f4c0414819cb1d5579dc08fd2a4f.1646905589.git.ps@pks.im/)

### Ref Update Locking Protocol

Ref updates use a lock-write-rename protocol:

1. **Atomically create** `refs/heads/mybranch.lock` (fails if file exists)
2. **Write** new SHA-1 to lock file
3. **Atomic rename** `.lock` -> target ref file
4. If lock creation fails (file exists) -> operation fails with `"cannot lock ref"`

**Implication for parallel worktrees**:
- Two worktrees updating **different branches** -> **no contention**, fully safe
- Two worktrees updating the **same ref** (e.g., both doing `git fetch` updating `refs/remotes/origin/main`) -> **transient lock failures** possible
- `git update-ref` supports batch atomic updates: if ALL refs can be locked simultaneously, all modifications proceed; otherwise none do

**Source**: [git-scm.com/docs/git-update-ref](https://git-scm.com/docs/git-update-ref)

### The gc Danger (Critical for Automation)

> "When git gc runs concurrently with another process, there is a risk of it deleting an object that the other process is using but hasn't created a reference to."

Git mitigates by keeping objects with recent modification times (within `gc.pruneExpire`, default 2 weeks). But for automated parallel systems:

```bash
# MANDATORY for parallel worktree automation:
git config gc.auto 0                    # Disable auto-gc entirely

# Conservative alternative:
git config gc.pruneExpire "1 month"     # Very long expiry window

# Run gc manually during quiet periods ONLY:
git gc --aggressive                     # When no agents are running
```

The `git maintenance run` command also takes an object database lock that prevents concurrent maintenance runs.

**Source**: [git-scm.com/docs/git-gc](https://git-scm.com/docs/git-gc), [git-scm.com/docs/git-maintenance](https://git-scm.com/docs/git-maintenance)

### Index Lock Isolation

Each worktree has its own index at `$GIT_DIR/worktrees/<name>/index`, with its own `index.lock`:

- **Same worktree**: Two git commands will contend on `index.lock` -> one fails
- **Different worktrees**: **No contention** -- completely independent index files

Lock file locations:
- Main worktree: `repo/.git/index.lock`
- Linked worktree wt-1: `repo/.git/worktrees/wt-1/index.lock`

**Source**: [pluralsight.com/guides/understanding-and-using-gits-indexlock-file](https://www.pluralsight.com/resources/blog/guides/understanding-and-using-gits-indexlock-file)

---

## A3. Worktree Lifecycle Management (Programmatic)

### Creation Patterns

```bash
# Standard: new branch from base
git worktree add <path> -b <new-branch> <base-commit>

# Existing branch (must not be checked out elsewhere)
git worktree add <path> <existing-branch>

# Detached HEAD (avoids branch exclusivity constraint)
git worktree add -d <path> <commit>

# Create and lock immediately (prevents pruning during automation)
git worktree add --lock --reason "Agent working" <path> -b <branch> <base>
```

### Listing (Machine-Parseable)

```bash
# Porcelain format for scripting
git worktree list --porcelain
# Output:
# worktree /path/to/main
# HEAD abc123def456
# branch refs/heads/main
#
# worktree /path/to/linked
# HEAD def456abc123
# branch refs/heads/feature
# locked

# Verbose (shows prunable/locked status, human-readable)
git worktree list -v
```

### Removal and Cleanup

```bash
# Clean removal (fails if dirty)
git worktree remove <path>

# Force (ignores untracked/modified files)
git worktree remove --force <path>

# Force on locked worktree (double --force)
git worktree remove --force --force <path>

# Prune stale metadata (worktree dir was deleted externally)
git worktree prune [--dry-run] [--verbose]

# Fix broken links
git worktree repair [<path>...]
```

### Automation Template

```bash
#!/bin/bash
REPO_DIR="/path/to/repo"
WORKTREE_BASE="${REPO_DIR}/.worktrees"
BRANCH_PREFIX="auto"

create_worktree() {
    local task_id="$1"
    local base_ref="${2:-HEAD}"
    local branch="${BRANCH_PREFIX}/${task_id}"
    local wt_path="${WORKTREE_BASE}/${task_id}"
    mkdir -p "${WORKTREE_BASE}"
    git -C "${REPO_DIR}" worktree add \
        --lock --reason "Task ${task_id}" \
        -b "${branch}" "${wt_path}" "${base_ref}"
    echo "${wt_path}"
}

remove_worktree() {
    local task_id="$1"
    local wt_path="${WORKTREE_BASE}/${task_id}"
    git -C "${REPO_DIR}" worktree unlock "${wt_path}" 2>/dev/null
    git -C "${REPO_DIR}" worktree remove --force "${wt_path}"
    git -C "${REPO_DIR}" branch -D "${BRANCH_PREFIX}/${task_id}" 2>/dev/null
}
```

---

## A4. Branch Naming Strategies

| Pattern | Example | Pros | Cons |
|---------|---------|------|------|
| `auto/<task-id>` | `auto/fix-login-123` | Clear automation prefix, easy to filter | None significant |
| `agent/<agent-id>/<task>` | `agent/claude-1/refactor-api` | Identifies source agent | Verbose |
| `wt/<timestamp>-<task>` | `wt/20260221-auth-fix` | Sortable by creation time | Timestamp clutter |
| `parallel/<spec-name>` | `parallel/add-caching` | Matches spec-driven workflow | Requires unique spec names |

**Recommendation**: `auto/<task-id>` -- filterable with `git branch --list 'auto/*'`, easy cleanup with `git branch --list 'auto/*' | xargs git branch -D`.

**Base branch rule**: All parallel worktrees should branch from the **same commit** (typically `main` HEAD) to minimize merge complexity. Never branch from another feature branch unless tasks have explicit dependencies.

---

## A5. Merge Strategies for N Parallel Branches (Detailed)

### Strategy Comparison

| Strategy | Mechanism | When to Use | Key Limitation |
|----------|-----------|-------------|----------------|
| **Sequential merge** | `git merge --no-ff` one branch at a time | Default safe choice | Order matters; later merges may conflict with earlier |
| **Octopus merge** | `git merge b1 b2 b3` single commit with N parents | All branches conflict-free | **Refuses if ANY conflict exists** |
| **Rebase chain** | Rebase each branch onto main sequentially | Clean linear history | Rewrites history; more conflict-prone |
| **Integration branch** | Merge all into temp branch, test, fast-forward main | CI/CD validation first | Extra branch management |
| **PR-based** | Each branch -> PR -> CI -> merge | Code review + CI per branch | Sequential by nature |

### Integration Branch Pattern (Recommended for Automation)

```bash
# 1. Create disposable integration branch
git checkout -b integration/batch-42 main

# 2. Merge all feature branches, handling conflicts
for branch in auto/task-1 auto/task-2 auto/task-3; do
    git merge --no-ff "$branch" || {
        echo "CONFLICT merging $branch -- skipping"
        git merge --abort
        # Queue for manual/AI resolution
    }
done

# 3. Run full CI/test suite on integration branch
# 4. If green, fast-forward main
git checkout main
git merge --ff-only integration/batch-42

# 5. Cleanup
git branch -d integration/batch-42
```

**Why this is best for automation**:
- Tests validate the combined result before main is touched
- Conflicts are caught on a disposable branch (main stays stable)
- Failed merges can be retried with AI-assisted resolution
- Preserves individual branch history for bisecting/reverting

### Octopus Merge Details

```bash
# Single commit with N+1 parents
git checkout main
git merge auto/task-1 auto/task-2 auto/task-3
```

- Default strategy when >2 branches specified
- **Refuses manual conflict resolution** -- aborts entirely if any conflict
- Practical limit: ~5-6 branches before diagnostic difficulty increases
- Best suited only when all branches touch completely disjoint file sets

**Source**: [atlassian.com/git/tutorials/using-branches/merge-strategy](https://www.atlassian.com/git/tutorials/using-branches/merge-strategy), [git-scm.com/docs/merge-strategies](https://git-scm.com/docs/merge-strategies)

### lesfurets/git-octopus Continuous Merge

More sophisticated approach for CI/CD:
- Continuously merge ALL feature branches into a disposable `octopus` branch
- Merge rebuilt on every push to any feature branch
- CI runs on the combined merge, not individual branches
- Individual branches merge to main independently when ready
- Can record conflict resolutions as refs for reuse

**Source**: [github.com/lesfurets/git-octopus](https://github.com/lesfurets/git-octopus)

---

## A6. Early Conflict Detection

### git merge-tree --write-tree (Git >= 2.38)

The most powerful tool for pre-merge conflict detection. Performs a **full merge in memory** without touching index or working directory:

```bash
# Basic conflict check (exit code: 0=clean, 1=conflicts, other=error)
git merge-tree --write-tree branch1 branch2
echo $?

# Quick check with early abort on first conflict
git merge-tree --write-tree --quiet branch1 branch2
echo $?

# Detailed: list conflicted files
git merge-tree --write-tree --name-only branch1 branch2
# Output on conflict:
# <tree-oid>
# path/to/conflicted/file.ts
# CONFLICT (content): Merge conflict in path/to/conflicted/file.ts
```

**Properties**:
- Does NOT modify working directory or index
- Uses same merge logic as `git merge` (rename detection, recursive/ort, directory/file conflicts)
- Can be run from ANY worktree (operates on object DB only)
- Supports `-X` strategy options (`-Xours`, `-Xtheirs`)
- Supports `--merge-base=<tree-ish>` for explicit base
- `--abort-on-conflict` exits early, avoids writing merge objects

**Source**: [git-scm.com/docs/git-merge-tree](https://git-scm.com/docs/git-merge-tree)

### Pairwise Conflict Matrix

For N parallel branches, check all O(N^2) pairs:

```bash
#!/bin/bash
branches=(auto/task-1 auto/task-2 auto/task-3 auto/task-4)

echo "Conflict Matrix:"
for i in "${!branches[@]}"; do
    for j in "${!branches[@]}"; do
        if [ "$i" -lt "$j" ]; then
            if git merge-tree --write-tree --quiet \
                "${branches[$i]}" "${branches[$j]}" > /dev/null 2>&1; then
                echo "  ${branches[$i]} x ${branches[$j]}: CLEAN"
            else
                echo "  ${branches[$i]} x ${branches[$j]}: CONFLICT"
            fi
        fi
    done
done
```

### File-Level Overlap Detection (Cheaper Heuristic)

Before running the full merge-tree check, identify which branch-pairs even touch the same files:

```bash
# Files changed by each branch relative to common ancestor
changed_by_task1=$(git diff --name-only main...auto/task-1)
changed_by_task2=$(git diff --name-only main...auto/task-2)

# Overlap detection
overlap=$(comm -12 \
    <(echo "$changed_by_task1" | sort) \
    <(echo "$changed_by_task2" | sort))

if [ -n "$overlap" ]; then
    echo "WARNING: File overlap between task-1 and task-2:"
    echo "$overlap"
    # Only run full merge-tree for overlapping pairs
fi
```

### Proactive Conflict Prevention

The best strategy is **architectural prevention**:
1. Assign non-overlapping file sets to parallel tasks
2. Keep each task's scope narrow (single module/feature)
3. Split large files before parallelizing work
4. Use file-level ownership awareness when dispatching tasks

---

## A7. Shared Resources: node_modules, Build Caches, .env

### The Problem

Worktrees only share git-tracked content. Untracked/ignored files do NOT exist in new worktrees:
- `node_modules/` -- absent
- `.env` -- absent
- `dist/` / `build/` -- absent
- `.venv/` -- absent

### Strategy Comparison

| Strategy | Mechanism | Speed | Disk Cost | Safety | Best For |
|----------|-----------|-------|-----------|--------|----------|
| **Fresh install** | `npm ci` per worktree | Slow (30-120s) | Full | Safest | Different deps per branch |
| **APFS clonefile** | `cp -Rc` on macOS | Instant (<1s) | Zero initially | Safe | macOS; same deps |
| **Symlink** | `ln -s` to main's dir | Instant | Zero | **DANGEROUS** | Never recommended |
| **pnpm store** | Content-addressable hardlinks | Fast | Deduplicated | Safe | pnpm projects |
| **Post-create script** | Hook runs after worktree creation | Varies | Varies | Controlled | Full automation |

### APFS Copy-on-Write (macOS -- Recommended)

On macOS with APFS (10.13+):

```bash
# Instant zero-cost clone of node_modules
cp -Rc "${REPO_DIR}/node_modules" "${wt_path}/node_modules"
```

- **Instant**: Only metadata written, data blocks shared with source
- **Zero disk cost**: Until files are modified, both copies share same physical blocks
- **Automatic divergence**: Modified blocks get new allocations transparently
- **Same-volume only**: Source and destination must be on same APFS volume
- **Not available on Linux**: Linux has different CoW mechanisms (btrfs reflinks)

For typical `node_modules` (~200MB-1GB):
- APFS clone: <1 second, 0 extra bytes
- Full `cp -R`: 10-60 seconds, full disk duplication
- `npm ci`: 30-120 seconds, full disk duplication + network

**Source**: [wadetregaskis.com/copy-on-write-on-apfs](https://wadetregaskis.com/copy-on-write-on-apfs/)

### Why Symlinks Are Dangerous

```bash
# DO NOT DO THIS:
ln -s ../main/node_modules ./node_modules
```

If ANY worktree runs `npm install` (even accidentally via a postinstall hook), it mutates the shared directory, corrupting dependencies for ALL worktrees simultaneously. There is no isolation.

### Worktree Setup Script Template

```bash
setup_worktree_env() {
    local wt_path="$1"
    local main_path="$2"

    # Dependencies (APFS clone on macOS, fresh install otherwise)
    if [[ "$(uname)" == "Darwin" ]]; then
        cp -Rc "${main_path}/node_modules" "${wt_path}/node_modules" 2>/dev/null
    else
        (cd "${wt_path}" && npm ci --silent)
    fi

    # Environment files
    cp "${main_path}/.env" "${wt_path}/.env" 2>/dev/null
    cp "${main_path}/.env.local" "${wt_path}/.env.local" 2>/dev/null

    # Build cache (if applicable)
    if [[ -d "${main_path}/.next" ]]; then
        cp -Rc "${main_path}/.next" "${wt_path}/.next" 2>/dev/null
    fi
}
```

### Cleanup: Background Deletion

Large `node_modules` can slow down `git worktree remove`:

```bash
cleanup_worktree() {
    local wt_path="$1"
    # Move node_modules to /tmp for background deletion
    if [ -d "${wt_path}/node_modules" ]; then
        local tmpdir="/tmp/nm-cleanup-$$-$(date +%s)"
        mv "${wt_path}/node_modules" "${tmpdir}"
        rm -rf "${tmpdir}" &  # Background deletion
    fi
    git worktree remove --force "${wt_path}"
}
```

---

## A8. Performance Considerations

### Disk Space Per Worktree

| Component | Cost | Notes |
|-----------|------|-------|
| Git object database | **0** (shared) | Main advantage over clones |
| Working directory | **Full checkout size** | All tracked files |
| Index file | ~1-5 MB | Proportional to file count |
| `node_modules` | **0** (APFS clone) to **full** | Depends on strategy |
| Build output | Full per worktree | Each builds independently |

**Example (typical JS project)**:
- Repository: 500MB (objects), 200MB working dir, 800MB node_modules
- Clone: 1.5 GB each
- Worktree + fresh install: 1.0 GB each
- Worktree + APFS clone: ~200MB each (until deps diverge)
- 10 worktrees: clone=15GB, worktree+APFS=2.5GB

### Filesystem Watch Scaling

| Tool | Issue | Mitigation |
|------|-------|------------|
| **FSEvent (macOS)** | Separate watchers per worktree | macOS handles well; practical limit ~50-100 |
| **inotify (Linux)** | Default max watches too low (8192) | `echo 524288 > /proc/sys/fs/inotify/max_user_watches` |
| **VS Code** | File watcher per workspace | Close unused worktree windows |
| **Webpack/Vite** | Dev server watches its worktree | Only run dev server in active worktree |

### git fsmonitor (Git >= 2.37)

Built-in filesystem monitor daemon changes `git status` from O(all files) to O(changed files):

```bash
git config core.useBuiltinFSMonitor true
# or
git config core.fsmonitor true
```

Particularly valuable with many worktrees or large working directories.

**Source**: [github.com/git-for-windows/git/discussions/3251](https://github.com/git-for-windows/git/discussions/3251)

### Git Operations Scaling

| Operation | Scaling with N worktrees | Notes |
|-----------|------------------------|-------|
| `git status` | O(1) per worktree | Only scans own working dir + index |
| `git worktree list` | O(N) | Reads all worktree metadata |
| `git gc` | O(objects), independent of N | But CONFLICTS with all active worktrees |
| `git fetch` | O(1) | Shared operation, benefits all worktrees |
| `git commit` | O(1) per worktree | Independent index per worktree |
| `git log` | O(1) | Shared object DB, same performance |

### Practical Scale Limits

| Constraint | Limit | Notes |
|------------|-------|-------|
| Disk space | ~10-20 worktrees | With APFS clones; fewer with full installs |
| File watchers | ~50-100 on macOS | Linux needs inotify tuning |
| Git operations | No practical limit | Each worktree operates independently |
| API rate limits | 3-10 agents | External constraint from LLM providers |
| Human oversight | 3-5 agents | Cognitive load for reviewing parallel output |

---

## A9. Concurrency Safety Summary

### What Is Safe to Do in Parallel

1. **Run `git add`, `git commit`, `git status`** in different worktrees -- fully independent
2. **Create branches** with different names -- per-ref locking, no contention
3. **Write objects** (commits, blobs, trees) -- content-addressed, idempotent
4. **Run `git fetch` once** before creating worktrees -- all benefit from shared objects

### What Requires Caution

1. **`git gc`** -- MUST be disabled (`gc.auto 0`) during parallel work
2. **`git fetch` in parallel** -- may see transient `"cannot lock ref"` on same remote refs
3. **Updating the same ref** from two worktrees -- will fail with lock error (but this shouldn't happen if branches are properly isolated)
4. **`git maintenance`** -- takes object DB lock; only one can run at a time

### What to Never Do

1. **Check out the same branch** in two worktrees (Git prevents this)
2. **Symlink node_modules** across worktrees (mutation corrupts all)
3. **Run gc during active parallel work** (may delete needed objects)
4. **Run multiple git commands simultaneously in the SAME worktree** (index.lock contention)

---

## A10. Additional Sources (Deep Dive)

- [git-scm.com/docs/git-worktree](https://git-scm.com/docs/git-worktree) -- Official worktree documentation
- [git-scm.com/docs/git-merge-tree](https://git-scm.com/docs/git-merge-tree) -- merge-tree documentation
- [git-scm.com/docs/git-update-ref](https://git-scm.com/docs/git-update-ref) -- Ref update atomicity
- [git-scm.com/docs/git-gc](https://git-scm.com/docs/git-gc) -- gc concurrent operation warnings
- [git-scm.com/docs/git-maintenance](https://git-scm.com/docs/git-maintenance) -- Maintenance locking
- [git-scm.com/docs/merge-strategies](https://git-scm.com/docs/merge-strategies) -- Merge strategy details
- [pluralsight.com/guides/understanding-and-using-gits-indexlock-file](https://www.pluralsight.com/resources/blog/guides/understanding-and-using-gits-indexlock-file) -- Index lock mechanics
- [about.gitlab.com/blog/2023/11/02/rearchitecting-git-object-database-mainentance-for-scale](https://about.gitlab.com/blog/2023/11/02/rearchitecting-git-object-database-mainentance-for-scale/) -- Object DB concurrency at scale
- [wadetregaskis.com/copy-on-write-on-apfs](https://wadetregaskis.com/copy-on-write-on-apfs/) -- APFS CoW details
- [docs.cline.bot/features/worktrees](https://docs.cline.bot/features/worktrees) -- Cline .worktreeinclude pattern
- [developers.openai.com/codex/app/worktrees](https://developers.openai.com/codex/app/worktrees/) -- Codex sync approach
- [github.com/lesfurets/git-octopus](https://github.com/lesfurets/git-octopus) -- Continuous merge workflow
- [github.com/max-sixty/worktrunk](https://github.com/max-sixty/worktrunk) -- Worktree management CLI for AI agents
