# Call-Center Queue Operations

Quick reference for inspecting and managing Asterisk queues running in the
`asterisk4` container (see [docker-compose.yml](../docker-compose.yml)).

Related configs:
- [asterisk_configs/queues.conf](../asterisk_configs/queues.conf)
- [asterisk_configs/queuerules.conf](../asterisk_configs/queuerules.conf)
- [asterisk_configs/extensions.conf](../asterisk_configs/extensions.conf)

---

## Feature codes (dial from a registered phone)

| Code              | Action                                          |
| ----------------- | ----------------------------------------------- |
| `8000`            | Enter the **support** queue as a caller         |
| `8001`            | Enter the **sales** queue as a caller           |
| `8500` / `8500<q>`| Log this phone into queue `<q>` (default `support`) |
| `8501` / `8501<q>`| Log this phone out of queue `<q>`               |
| `8502`            | Toggle pause across all queues for this phone   |

Membership is persisted in `astdb` (`persistentmembers=yes`), so agents
stay logged in across Asterisk restarts.

---

## Asterisk CLI commands

Run from the host (PowerShell). All commands are wrapped in
`docker exec asterisk4 asterisk -rx "..."`.

### Inspect

```powershell
# All queues, members, callers, stats
docker exec asterisk4 asterisk -rx "queue show"

# One specific queue
docker exec asterisk4 asterisk -rx "queue show support"

# Just the lines that matter
docker exec asterisk4 asterisk -rx "queue show support" |
    Select-String "PJSIP|Members|Callers"

# Live stats summary
docker exec asterisk4 asterisk -rx "queue statistics"

# Loaded penalty rules
docker exec asterisk4 asterisk -rx "queue show rules"
```

Sample output of `queue show support`:

```
support       has 0 calls (max unlimited) in 'ringall' strategy
              (0s holdtime, 0s talktime), W:0, C:0, A:0, SL:0.0%, SL2:0.0% within 60s
   Members:
      PJSIP/7000 (ringinuse disabled) (dynamic) (Not in use) has taken no calls yet
      PJSIP/7001 (ringinuse disabled) (dynamic) (paused:lunch) has taken 3 calls (last 42s ago)
   No Callers
```

Key fields per member:
- Device state: `Not in use`, `In use`, `Ringing`, `Unavailable`, `Invalid`
- `(paused[:reason])` — paused agents do not receive calls
- `has taken N calls (last was Ns ago)`

### Manage

```powershell
# Add / remove a member dynamically
docker exec asterisk4 asterisk -rx "queue add member PJSIP/7000 to support penalty 0"
docker exec asterisk4 asterisk -rx "queue remove member PJSIP/7000 from support"

# Pause / unpause (omit queue name to apply to ALL queues the member is in)
docker exec asterisk4 asterisk -rx "queue pause member PJSIP/7000 queue support reason lunch"
docker exec asterisk4 asterisk -rx "queue unpause member PJSIP/7000 queue support"

# Reset stats counters for a queue
docker exec asterisk4 asterisk -rx "queue reset stats support"

# Reload after editing queues.conf / queuerules.conf
docker exec asterisk4 asterisk -rx "queue reload all"

# Reload dialplan after editing extensions.conf
docker exec asterisk4 asterisk -rx "dialplan reload"
```

---

## Logs

`queue_log` records every `ENTERQUEUE`, `ABANDON`, `CONNECT`, `COMPLETE*`,
`ADDMEMBER`, `REMOVEMEMBER`, `PAUSE`, `UNPAUSE` event:

```powershell
docker exec asterisk4 tail -f /var/log/asterisk/queue_log
```

Full Asterisk log:

```powershell
docker exec asterisk4 tail -f /var/log/asterisk/messages
```

---

## Asterisk Manager Interface (AMI)

AMI is exposed on `5038/tcp` (see [asterisk_configs/manager.conf](../asterisk_configs/manager.conf)).

Key actions:

| Action          | Purpose                                            |
| --------------- | -------------------------------------------------- |
| `QueueStatus`   | Detailed `QueueParams` + `QueueMember` + `QueueEntry` events |
| `QueueSummary`  | One-event-per-queue rollup                         |
| `QueueAdd`      | Add a dynamic member                               |
| `QueueRemove`   | Remove a dynamic member                            |
| `QueuePause`    | Pause / unpause a member                           |
| `QueueReset`    | Reset stats                                        |
| `QueueLog`      | Inject a custom queue_log event                    |

Example (raw protocol):

```
Action: Login
Username: admin
Secret: <secret>

Action: QueueStatus
Queue: support
ActionID: 1
```

---

## Dialplan functions (use inside `extensions.conf`)

```
${QUEUE_MEMBER(support,count)}      ; total members
${QUEUE_MEMBER(support,free)}       ; idle, not paused
${QUEUE_MEMBER(support,ready)}      ; idle, not paused, not in wrapup
${QUEUE_MEMBER(support,paused)}
${QUEUE_WAITING_COUNT(support)}     ; callers waiting
${QUEUE_VARIABLES(support)}         ; populates QUEUEMAX, QUEUESTRATEGY,
                                    ;   QUEUECALLS, QUEUEHOLDTIME,
                                    ;   QUEUECOMPLETED, QUEUEABANDONED,
                                    ;   QUEUESRVLEVEL, QUEUESRVLEVELPERF
```

---

## Troubleshooting

| Symptom                                  | Check                                              |
| ---------------------------------------- | -------------------------------------------------- |
| `queue show` lists no queues             | `queues.conf` mounted? `docker exec asterisk4 ls /etc/asterisk/queues.conf` |
| Member shown as `Unavailable` / `Invalid`| Endpoint not registered — `pjsip show endpoints`   |
| Caller hears silence then hangup         | `joinempty` / `leavewhenempty` rules — see queues.conf |
| Login feature code does nothing          | `dialplan reload`; verify `CALLERID(num)` is set   |
| Edits to `queues.conf` ignored           | `queue reload all` (config is cached)              |
