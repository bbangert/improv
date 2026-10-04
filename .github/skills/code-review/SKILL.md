---
name: code-review
description: Reviews Elixir and Erlang changes against the principles of Designing Elixir Systems with OTP — process boundaries, single ownership of state, supervision trees that express restart characteristics, and let-it-crash recovery. Use when reviewing any pull request in an Elixir, Erlang, Phoenix, or OTP project, especially changes to GenServers, Supervisors, Registry, ETS, PubSub, Tasks, or process lifecycle.
---

# Reviewing OTP code

The bar is *Designing Elixir Systems with OTP*: data, functions, tests,
boundaries, lifecycles, workers. Raise a finding when code is in the wrong
layer — state without one owner, a lifecycle managed from outside the tree,
a boundary crossed by a call that should be a message — not when it could be
more defensive. Judge concerns against the project's stated deployment
shape: a race that needs a second node, tenant, or operator does not occur
in a system that has none, and coordination added to prevent it is a
regression.

**The tree owns process lifetime.** Restart behaviour is where a process
sits and its parent's strategy, never another process deciding for it.
Strategy expresses restart coupling: `:rest_for_one` where an earlier
child's replacement invalidates the later ones, `:one_for_one` where each
recovers on its own — a later child that survives the earlier one's
replacement through its own recovery does not need restarting with it. Child order is
chosen for start and, in reverse, for stop. A retry, a stash, a
reconcile-on-restart, or a process reaching across trees is wrong when it
compensates for lifetime owned in the wrong place; the same mechanisms are
legitimate for transient external failure, durable recovery, or
backpressure. Ask what the mechanism compensates for.

Runtime facts a finding may rest on — restart types, shutdown budgets,
restart intensity, start and continue, exit reasons, calls and mailboxes,
message ordering, Tasks, Registry, child management, strategy coupling,
tables and terms, timers — are in
[references/otp-semantics.md](references/otp-semantics.md), each with the
production case where the "wrong" choice is right. Read it before
asserting any of them.

## Flag these classes

- **A process that does not earn its existence.** A process is justified
  by a runtime property — concurrency, serialized access to a shared
  resource, an isolation domain, state that outlives a call — never by code
  organization or a namespace. A GenServer kept as a serialization point is
  a legitimate bottleneck; one wrapping pure functions is not.
- **A call from `init/1` back to the process starting the tree.** A child
  started from inside a server's `handle_call` that calls that server
  deadlocks until timeout. Config reaches a child through start arguments
  or a `:persistent_term`/ETS snapshot, and the same for anything the child
  starts from its own init.
- **Post-init work that is not `handle_continue`.** Work in `init/1` blocks
  the starter and, under a supervisor, the start sequence; `{:continue, _}`
  runs before any message a registered name already attracts. Work belongs in
  `init/1` when its outcome must be the start result — a starter that must
  see the failure, or must never observe a half-ready process — or when a
  later child must wait for this one.
- **An unbounded producer into a slower consumer.** A mailbox is bounded
  only by memory, so a `cast` or `send` path with nothing pacing it fails
  as node memory, with no error where it was sent. A `call` paces one caller,
  not the aggregate — many callers still grow the mailbox — so the bound
  is admission control or observable shedding, and silent dropping is the
  bug.
- **A restart type or budget that does not say what it means.** A
  `:transient` child does not come back from its own clean stop; a
  `:temporary` one runs once and is forgotten; `:infinity` shutdown on a
  worker holds the whole tree's teardown; a DynamicSupervisor with no
  `:max_children` on a per-request path has no ceiling. Each is right
  somewhere; the review asks whether it was chosen.
- **A worker that dies with a table or process it does not own.** Callers
  outliving an ETS owner with no heir raise on the missing table; callers of
  a restarting named process exit; on a restore path that is a child failing
  to start and escalating. The owner's API must state its contract for an
  absent owner — best-effort state reads empty and drops the write, durable
  state fails loudly or is retried — and callers die with the owner only
  when the tree says they should.
- **A subscription assumed to survive its holder's replacement.** Subscriber
  lists live in the holder's state. Where the tree does not restart the
  subscriber with the holder, there must be an explicit mechanism — a
  monitor, a readiness announcement, restoration from durable state — and
  whoever detects the loss reports to whoever owns the outcome rather than
  acting on a stale snapshot.
- **The wrong process closing a record.** A process closes the handle it
  holds when it is done. The record describing the work belongs to the
  process that has been updating it; a helper finalizing it persists the
  opening snapshot and skips the owner's notifications. Only an orphan
  (owner dead) finalizes the record itself, and then emits what the owner
  would have.
- **Ordering relied on across a pair the messages do not share.** Two
  messages that must arrive in order leave the same process for the same
  process; a third process, or a different sender, reorders them.
- **Configuration reaching work by accident.** The project's contract
  decides whether a change applies to in-flight work or only to the next
  unit; either must be deliberate — a copy captured at open, a read of the
  current value at a defined boundary, or an explicit cancel — never live
  state read because a timer happened to arm. A held struct
  that flows into processes the worker starts must be refreshed on every
  change class that can reach it.
- **Child order that makes the stop lie.** If a producer stops before the
  consumer that must close cleanly, the consumer records the producer's stop
  as a failure. What must close first goes last in the child list.
- **A read-path lookup treated as liveness.** A name lookup can return a
  dead pid; `Process.alive?/1` filters that stale entry and nothing more,
  since the process can exit right after. Where correctness depends on the
  target handling the operation, the protocol is a call or a monitor that
  observes the outcome, not a check before the act.
- **`terminate/2` doing less than the normal close, or more than it can.**
  A process that must close on an external `:shutdown` traps exits — and
  then every linked peer's failure arrives as an `EXIT` message it must
  handle, where before it would have taken the process down — runs the
  ordinary close in the ordinary order, and returns without awaiting other
  processes. What a crash reason must do
  follows the resource's recovery contract, and because a kill skips the
  callback, an external handle must also be owned by the process or
  recoverable by its successor.
- **A comment declaring a case impossible.** "Can never", "the only
  caller", "already announced" are the claims most often false after a
  refactor and most often hiding a defect. Check them against the code.
- **A test that passes in both states.** A test pinning a fix must fail
  without it. Prefer real processes and timers to stubs and manual firing
  when ordering or duration is under test; synchronize with monitors,
  `assert_receive`, and `:sys.get_state/1`, never `Process.sleep` polling.
  A guard against calling a named singleton must run against that
  singleton, not a private instance the lookup never resolves to.

## Do not suggest these

- **A reaper, reconciler, or stop-time sweep** that compensates for
  lifetime owned in the wrong tree. A stop is a supervisor stopping a
  subtree; each worker closes its own resources in `terminate/2`; a crash
  restores from a checkpoint. A worker crashing at the instant its subtree
  stops is a double fault to document, not an orchestrator to build. A
  successor reconciling durable external resources its predecessor was
  killed holding is not this — that is the recovery the kill demands.
- **An explicit stop signal** to tell an intentional stop from a crash. The
  exit reason a link or monitor delivers already says which, and the
  stopping process receives the same reason in `terminate/2`.
- **A call in place of a cast** to close a window that ordering does not
  close anyway. Ask whether the outcome inside the window is already honest.
- **Waits on registry unregistration before a re-register**, guards
  against `terminate_child` failing on a down child whose spec remains (a
  `:temporary` child's is deleted on exit, and that one does return
  `:not_found`), a `start_link` timeout added because someone assumed a five-second
  default (a deliberate `:timeout` that bounds an init hanging on an
  external dependency is a different thing, and valid), or guards on `Process.exit` of a dead pid — see
  the reference; each was asserted in review and shown false by running it.
  A read used to decide whether something is still running is the one
  place a Registry wait or an alive check belongs, and there it only
  filters a stale entry; the decision that follows still needs a protocol
  that observes the target.
- **Hibernation or a `PartitionSupervisor` without a measurement.** The
  first trades a GC per message for a compact heap, the second shards a
  singleton whose contention has not been shown; both are right after the
  number, not before.
- **Cluster or multi-node concerns** in a single-node project. Generator
  boilerplate such as `DNSCluster` is not evidence of a cluster.
- **Per-subscriber hardening against a shared service's restart** where
  the topology already restarts the subscribers with the service. Where
  they are independent, resubscription is a real recovery path; ask for it.

## Writing a finding

For a process-interaction or lifecycle finding, name the layer violated —
boundary, lifecycle, ownership, ordering — and give the sequence: which
process sends what to whom, in what order, and what the user then sees. A
finding of that kind that cannot be stated as a sequence is a preference;
do not raise it. Objective defects — a compile error, a misused API, a
security hole — need no sequence. When the fix is structural — a child
order, a strategy, an owner — say so instead of proposing a guard. State
any runtime semantic a claim rests on, from the reference.
