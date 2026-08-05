#!/usr/bin/env python3
"""Generate a fake ~/.claude/projects tree so Sift can be run and screenshotted
without putting anyone's real session titles on the internet.

    python3 scripts/demo-data.py /tmp/sift-demo/projects
    SIFT_PROJECTS_ROOT=/tmp/sift-demo/projects SIFT_SUPPORT_DIR=/tmp/sift-demo/support \\
      /Applications/Sift.app/Contents/MacOS/Sift        # quit once it has indexed
    python3 scripts/demo-data.py --brain-only /tmp/sift-demo/support
    SIFT_PROJECTS_ROOT=/tmp/sift-demo/projects \
    SIFT_SUPPORT_DIR=/tmp/sift-demo/support \
    /Applications/Sift.app/Contents/MacOS/Sift

Writes the same JSONL shape Claude Code does: one object per line, `cwd` and
`gitBranch` on the first, then alternating user/assistant messages.
"""
from __future__ import annotations

import json
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJECTS = [
    ("/Users/alex/code/orbit-api", "main", [
        ("Rate limiter drops the first request after a restart",
         "The token bucket starts empty instead of full, so the very first call after a "
         "deploy is rejected. Should it start full?",
         "It should start full. An empty bucket means every deploy briefly rejects traffic, "
         "which reads as an outage to callers. I moved the initial fill into the constructor "
         "and added a test that asserts the first request after construction succeeds."),
        ("Postgres connection pool exhausted under load",
         "We hit 'sorry, too many clients already' at about 300 rps. Pool size is 20.",
         "The pool is fine; connections are leaking. Three handlers acquire a connection "
         "before an early return and never release it. Wrapping acquisition in a context "
         "manager fixes all three, and the leak test now fails without it."),
        ("Add cursor pagination to the events endpoint",
         "Offset pagination is getting slow past page 200. Move to cursors.",
         "Switched to keyset pagination on (created_at, id). Page 200 went from 1.9s to 11ms. "
         "The old offset parameter still works and is marked deprecated in the OpenAPI spec."),
        ("Why does the health check flap in staging?",
         "The health endpoint returns 503 every few minutes but the service is fine.",
         "The check runs a real query against the replica, and the replica pauses briefly "
         "during WAL replay. Point the liveness probe at a plain process check and keep the "
         "query for readiness only."),
    ]),
    ("/Users/alex/code/atlas-web", "feat/checkout", [
        ("Checkout form loses state on validation error",
         "If the card number is wrong, the whole form resets and the user has to retype the "
         "address. Very annoying.",
         "The form component is remounting because its key includes the error object, which "
         "is a new reference on every render. Keying on a stable id keeps the state and the "
         "typed values survive a failed validation."),
        ("Bundle size jumped 400KB after the last merge",
         "Something in the last release added a lot of weight. Can you find it?",
         "A date library got pulled in through a single `format` call in the receipt view. "
         "Replacing it with Intl.DateTimeFormat drops 380KB. The remaining 20KB is an icon "
         "set that is now loaded lazily."),
        ("Dark mode flashes white on first paint",
         "There is a white flash before the dark theme applies.",
         "The theme is applied in a useEffect, so the first paint is always light. Moving the "
         "class onto the html element in an inline script that runs before the stylesheet "
         "removes the flash."),
        ("Migrate the data grid to virtualised rows",
         "The table locks up with more than 2000 rows.",
         "Virtualised the body with a fixed row height and kept the header sticky outside the "
         "scroll container. 10,000 rows now scroll at 60fps; sorting stayed on the server."),
    ]),
    ("/Users/alex/code/ledger-cli", "main", [
        ("Parse dates without a timezone as local, not UTC",
         "Entries dated 2026-01-05 show up as the 4th for anyone west of UTC.",
         "The parser was calling the UTC constructor for bare dates. Bare dates are wall-clock "
         "dates and should be local. Fixed, with a test that pins the behaviour under three "
         "different TZ settings."),
        ("Add a --since flag to the report command",
         "I want to run reports over the last quarter without editing the config.",
         "Added --since and --until accepting either an ISO date or a relative form like "
         "'3 months'. They compose with the existing account filter."),
        ("Rounding drift in multi-currency totals",
         "Totals are off by a cent or two on large reports.",
         "Amounts were being converted to float for the sum. Keeping everything in integer "
         "minor units and converting only for display removes the drift entirely."),
    ]),
    ("/Users/alex/code/pipeline-runner", "fix/retries", [
        ("Retries hammer the API instead of backing off",
         "We retry five times in about a second, which is not helping.",
         "There was no delay between attempts at all. Added exponential backoff with full "
         "jitter, capped at 30 seconds, and made the retry budget per-job rather than global."),
        ("Jobs stuck in 'running' after the worker is killed",
         "If the worker dies, jobs never move out of running and block the queue.",
         "Added a lease with a heartbeat. A job whose lease expires is returned to the queue, "
         "and the worker checks its own lease before committing results, so a resumed job "
         "cannot write twice."),
        ("Log lines interleave when jobs run in parallel",
         "Output from different jobs is mixed together and unreadable.",
         "Each job now writes to its own buffer and flushes whole lines under a lock. Added the "
         "job id as a prefix so a shared terminal is still readable."),
    ]),
    ("/Users/alex/notes", "main", [
        ("Summarise this week's architecture decisions",
         "Go through the decision records from this week and give me the short version.",
         "Three decisions: keyset pagination replaces offset across all list endpoints; job "
         "leases replace the old heartbeat table; currency amounts stay in integer minor units "
         "end to end. The first two are already implemented."),
        ("Draft the release notes for 2.4",
         "Turn the merged PRs since 2.3 into release notes for people who do not read commits.",
         "Grouped into three sections: faster listings, jobs that recover from a killed worker, "
         "and correctness fixes around currency and dates. Each line says what changed for the "
         "reader rather than which function moved."),
    ]),
    ("/Users/alex/code/sift", "main", [
        ("Search is slow once the index passes 5000 sessions",
         "Queries take about a second now. It used to be instant.",
         "The FTS table was being joined before the filters narrowed the set. Moving the "
         "structured filters into the same query and ranking with BM25 column weights brings "
         "a 6000-session library back to about 30ms."),
        ("The graph view shows no edges at all",
         "Every node is floating on its own even though relations exist.",
         "Nodes and edges were selected with two independent limits, so almost no edge had "
         "both endpoints in the node set. Selecting the edges for the chosen nodes in one "
         "query fixes it."),
    ]),
]

FOLLOW_UPS = [
    ("Can you add a test that would have caught this?",
     "Added one that reproduces the original failure and fails against the previous code."),
    ("What is the performance impact?",
     "Measured before and after on the same input: no measurable regression, and the hot path "
     "does one less allocation per call."),
    ("Anything else worth changing while we are here?",
     "Two nearby spots have the same shape of bug. I left them alone since they are not in "
     "scope, but they are worth a follow-up."),
]


def encode_path(path: str) -> str:
    """Matches PathCodec.encode: path separators become dashes."""
    return path.replace("/", "-")


def write_session(directory: Path, cwd: str, branch: str, title: str,
                  prompt: str, reply: str, started: datetime, turns: int) -> None:
    session_id = str(uuid.uuid4())
    lines = []
    stamp = started

    def at(offset_seconds: int) -> str:
        return (stamp + timedelta(seconds=offset_seconds)).isoformat().replace("+00:00", "Z")

    lines.append({
        "type": "user", "sessionId": session_id, "cwd": cwd, "gitBranch": branch,
        "entrypoint": "cli", "version": "2.4.1", "timestamp": at(0),
        "message": {"role": "user", "content": prompt},
    })
    lines.append({
        "type": "assistant", "sessionId": session_id, "timestamp": at(35),
        "message": {"role": "assistant", "content": [{"type": "text", "text": reply}]},
    })
    for i in range(turns):
        follow_prompt, follow_reply = FOLLOW_UPS[i % len(FOLLOW_UPS)]
        lines.append({
            "type": "user", "sessionId": session_id, "timestamp": at(120 + i * 180),
            "message": {"role": "user", "content": follow_prompt},
        })
        lines.append({
            "type": "assistant", "sessionId": session_id, "timestamp": at(160 + i * 180),
            "message": {"role": "assistant",
                        "content": [{"type": "text", "text": follow_reply}]},
        })
    lines.append({"type": "ai-title", "sessionId": session_id, "title": title,
                  "timestamp": at(200 + turns * 180)})

    path = directory / f"{session_id}.jsonl"
    with path.open("w", encoding="utf-8") as handle:
        for entry in lines:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


# A second brain fills up fast, so the demo graph is built at a realistic scale rather
# than a handful of nodes: name pools per entity kind, then edges by preferential
# attachment so a few hubs emerge the way they do in real use.

PROJECT_NAMES = [
    "orbit-api", "atlas-web", "ledger-cli", "pipeline-runner", "sift", "harbor-sync",
    "beacon-auth", "quarry-etl", "meridian-ui", "tundra-store", "cinder-queue", "vellum-docs",
]
TOOL_NAMES = [
    "PostgreSQL", "SQLite", "Redis", "Kafka", "Docker", "Kubernetes", "Terraform", "nginx",
    "Grafana", "Prometheus", "GitHub Actions", "pytest", "Playwright", "esbuild", "Xcode",
    "ripgrep", "jq", "curl", "OpenSearch", "MinIO",
]
LIB_NAMES = [
    "GRDB", "FTS5", "SwiftUI", "Combine", "React", "TanStack Query", "Zod", "Prisma",
    "SQLAlchemy", "Pydantic", "FastAPI", "httpx", "Tokio", "serde", "Alembic", "Vitest",
    "Testcontainers", "OpenTelemetry", "Sentry", "Zustand",
]
PEOPLE = ["Dana", "Priya", "Marco", "Yuki", "Ines", "Tobias", "Nour", "Ada"]
FILE_NAMES = [
    "schema.sql", "migrations.py", "IndexStore.swift", "SessionScanner.swift", "router.ts",
    "checkout.tsx", "worker.py", "lease.py", "Dockerfile", "ci.yml", "conftest.py",
    "settings.toml", "openapi.yaml", "BrainStore.swift", "GraphLayout.swift", "cache.rs",
    "auth_middleware.py", "retry.ts", "TableView.tsx", "report.py", "bootstrap.sh",
    "telemetry.py", "fixtures.json", "seed.sql", "Package.swift",
]
CONCEPT_NAMES = [
    "keyset pagination", "connection pooling", "exponential backoff", "job leases",
    "BM25 ranking", "virtualised rows", "integer minor units", "wall-clock dates",
    "token bucket", "full-text search", "idempotency keys", "optimistic locking",
    "write-ahead logging", "read replicas", "cache invalidation", "circuit breaker",
    "graceful shutdown", "backpressure", "dead letter queue", "at-least-once delivery",
    "schema migration", "blue-green deploy", "feature flags", "canary release",
    "structured logging", "distributed tracing", "cardinality explosion", "p99 latency",
    "N+1 queries", "covering index", "partial index", "query planner", "vacuum tuning",
    "prepared statements", "row-level security", "content hashing", "debouncing",
    "virtual scrolling", "code splitting", "tree shaking", "hydration mismatch",
    "server components", "optimistic UI", "stale-while-revalidate", "ETags",
    "content negotiation", "cursor stability", "clock skew", "leap seconds",
    "timezone handling", "unicode normalisation", "collation", "fuzzy matching",
    "prefix indexes", "inverted index", "embedding drift", "cosine similarity",
    "chunking strategy", "context window", "prompt caching", "token budget",
    "retry budget", "jitter", "leader election", "quorum reads", "split brain",
    "eventual consistency", "saga pattern", "outbox pattern", "change data capture",
    "bulk upsert", "batch windows", "watermarking", "late arrivals", "sharding key",
    "hot partitions", "rebalancing", "consistent hashing", "bloom filters",
    "LRU eviction", "memory pressure", "allocation churn", "copy-on-write",
    "value semantics", "actor isolation", "data races", "structured concurrency",
    "cancellation", "task priority", "main-actor hops", "retain cycles",
    "ad-hoc signing", "notarisation", "sandboxing", "TCC prompts", "launch agents",
    "atomic writes", "file coordination", "inode reuse", "symlink traps",
    "path encoding", "case-insensitive filesystems", "exFAT quirks",
]

PREDICATES = ["uses", "adopted", "depends on", "replaces", "implements", "documents",
              "owns", "reviewed", "touches", "mitigates"]

ATOM_TEMPLATES = [
    ("D", "{a} replaces {b} across the codebase", 8),
    ("F", "{a} is the reason {b} regressed under load", 7),
    ("H", "Reach for {a} before {b}; it fails more loudly", 7),
    ("P", "Prefer {a} over {b} in new code", 6),
    ("V", "{a} cut p99 latency roughly in half in {b}", 6),
    ("F", "{a} and {b} disagree about clock skew", 5),
    ("D", "{a} is the single source of truth for {b}", 8),
    ("H", "When {a} misbehaves, check {b} first", 7),
]


def build_graph(rng):
    """Entities plus edges. Preferential attachment gives a few dense hubs and a
    long tail, which is what a real knowledge graph looks like."""
    entities = []
    for name in PROJECT_NAMES:
        entities.append((name, "project"))
    for name in TOOL_NAMES:
        entities.append((name, "tool"))
    for name in LIB_NAMES:
        entities.append((name, "lib"))
    for name in PEOPLE:
        entities.append((name, "person"))
    for name in FILE_NAMES:
        entities.append((name, "file"))
    for name in CONCEPT_NAMES:
        entities.append((name, "concept"))

    by_kind = {}
    for name, kind in entities:
        by_kind.setdefault(kind, []).append(name)

    edges = set()
    degree = {name: 1 for name, _ in entities}

    def attach(source, pool, predicate):
        weights = [degree[c] for c in pool]
        target = rng.choices(pool, weights=weights, k=1)[0]
        if target != source:
            edges.add((source, predicate, target))
            degree[source] += 1
            degree[target] += 1

    for project in by_kind["project"]:
        for _ in range(rng.randint(3, 6)):
            attach(project, by_kind["lib"], "uses")
        for _ in range(rng.randint(2, 5)):
            attach(project, by_kind["tool"], "uses")
        for _ in range(rng.randint(4, 9)):
            attach(project, by_kind["concept"], "adopted")
    for path in by_kind["file"]:
        attach(path, by_kind["project"], "touches")
        for _ in range(rng.randint(1, 3)):
            attach(path, by_kind["concept"], "implements")
    for person in by_kind["person"]:
        for _ in range(rng.randint(2, 4)):
            attach(person, by_kind["project"], "owns")
        for _ in range(rng.randint(1, 3)):
            attach(person, by_kind["concept"], "reviewed")
    for lib in by_kind["lib"] + by_kind["tool"]:
        for _ in range(rng.randint(1, 3)):
            attach(lib, by_kind["concept"], "implements")
    for concept in by_kind["concept"]:
        for _ in range(rng.randint(1, 3)):
            attach(concept, by_kind["concept"], rng.choice(PREDICATES))

    return entities, sorted(edges)


ATOM_TEMPLATES = [
    ("D", "{a} replaces {b} across the codebase", 8),
    ("F", "{a} is the reason {b} regressed under load", 7),
    ("H", "Reach for {a} before {b}; it fails more loudly", 7),
    ("P", "Prefer {a} over {b} in new code", 6),
    ("V", "{a} cut p99 latency roughly in half in {b}", 6),
    ("F", "{a} and {b} disagree about clock skew", 5),
    ("D", "{a} is the single source of truth for {b}", 8),
    ("H", "When {a} misbehaves, check {b} first", 7),
]

def base62(n: int) -> str:
    chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    out = ""
    for _ in range(10):
        out = chars[n % 62] + out
        n //= 62
    return out


def seed_brain(db_path: Path) -> tuple[int, int]:
    import sqlite3

    rng = random.Random(20260805)
    entities, edges = build_graph(rng)

    conn = sqlite3.connect(db_path)
    ids = {}
    for i, (name, kind) in enumerate(entities):
        eid = base62(1000 + i)
        ids[name] = eid
        conn.execute('INSERT OR REPLACE INTO entity (id, n, k) VALUES (?, ?, ?)', (eid, name, kind))

    now = datetime.now(timezone.utc).timestamp()
    names = [name for name, _ in entities]
    for i in range(140):
        kind, template, importance = rng.choice(ATOM_TEMPLATES)
        a, b = rng.sample(names, 2)
        aid = base62(5000 + i)
        conn.execute(
            'INSERT OR REPLACE INTO atom (id, t, s, proj, src, imp, createdAt, retrievals)'
            ' VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
            (aid, kind, template.format(a=a, b=b), None, f"demo:{i}", importance, now - i * 1800))
        for mention in (a, b):
            conn.execute('INSERT OR REPLACE INTO atom_entity (atomId, entityId) VALUES (?, ?)',
                         (aid, ids[mention]))

    for i, (subject, predicate, obj) in enumerate(edges):
        conn.execute(
            'INSERT OR REPLACE INTO relation (id, subjectId, predicate, objectId, src)'
            ' VALUES (?, ?, ?, ?, ?)',
            (base62(9000 + i), ids[subject], predicate, ids[obj], f"demo:{i}"))

    conn.commit()
    conn.close()
    return len(entities), len(edges)



LOOPS = [
    ("Keep the OpenAPI spec in step with the routes",
     "Compare the route table against openapi.yaml and add whatever is missing.",
     "/Users/alex/code/orbit-api", "Every route appears in the spec with a response schema.",
     "agent", 3, "passed", 2),
    ("Get the flaky checkout test green",
     "Find why checkout.spec.ts fails about one run in five and fix the cause.",
     "/Users/alex/code/atlas-web", "npx vitest run checkout.spec.ts", "shell", 5, "passed", 3),
    ("Cut the cold-start time under 400ms",
     "Profile the worker boot path and remove the slowest avoidable work.",
     "/Users/alex/code/pipeline-runner", "Boot completes in under 400ms on a cold cache.",
     "agent", 4, "idle", 0),
]


def seed_loops(db_path: Path) -> int:
    """Loops live in their own database, seeded the same way the brain is."""
    import sqlite3

    if not db_path.exists():
        return 0
    conn = sqlite3.connect(db_path)
    now = datetime.now(timezone.utc).timestamp()
    for i, (title, prompt, cwd, done, kind, passes, state, attempt) in enumerate(LOOPS):
        conn.execute(
            'INSERT OR REPLACE INTO loop_task (id, title, prompt, cwd, doneWhen, checkKind,'
            ' maxPasses, rememberOnPass, state, lastAttempt, createdAt, updatedAt)'
            ' VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)',
            (base62(7000 + i), title, prompt, cwd, done, kind, passes, state, attempt,
             now - (i + 1) * 7200, now - (i + 1) * 3600))
    conn.commit()
    conn.close()
    return len(LOOPS)


def main() -> int:
    args = sys.argv[1:]
    # The knowledge graph has to be seeded AFTER the app has created and migrated
    # brain.sqlite, or GRDB's migrator meets tables it did not create and refuses.
    if args and args[0] == "--brain-only":
        if len(args) < 2:
            print(__doc__)
            return 2
        support = Path(args[1]).expanduser()
        nodes, links = seed_brain(support / "brain.sqlite")
        loops = seed_loops(support / "loops.sqlite")
        print(f"seeded {nodes} entities, {links} relations and {loops} loops into {support}")
        return 0

    if not args:
        print(__doc__)
        return 2
    root = Path(args[0]).expanduser()
    if root.exists():
        print(f"refusing to write into an existing directory: {root}", file=sys.stderr)
        return 1
    root.mkdir(parents=True)

    rng = random.Random(20260805)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    written = 0

    for cwd, branch, sessions in PROJECTS:
        directory = root / encode_path(cwd)
        directory.mkdir(parents=True, exist_ok=True)
        for title, prompt, reply in sessions:
            # Spread across the last three weeks, with a few from today so the
            # "Today" list and the activity heatmap both have something to show.
            age_hours = rng.choice([1, 3, 7, 26, 30, 52, 74, 99, 122, 170, 220, 300, 400, 500])
            started = now - timedelta(hours=age_hours, minutes=rng.randint(0, 59))
            write_session(directory, cwd, branch, title, prompt, reply,
                          started, turns=rng.randint(1, 3))
            written += 1

    print(f"wrote {written} sessions across {len(PROJECTS)} projects into {root}")
    print("now launch Sift once so it builds its databases, then run:")
    print("  python3 scripts/demo-data.py --brain-only <SIFT_SUPPORT_DIR>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
