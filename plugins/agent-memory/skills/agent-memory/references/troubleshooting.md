# Troubleshooting

## The tools are missing, or every call fails to connect

The memory service runs in a container on the person's machine, at `http://127.0.0.1:39142/mcp`.
The plugin only registers that address; it doesn't start anything. If the tools are missing or
the connection fails:

1. Check whether it is up: `curl -s http://127.0.0.1:39142/.well-known/oauth-authorization-server`
   answers with a small JSON document when the service is running. No answer means the container
   is not running.
2. Tell the person. Starting it is their act: `docker start agent-memory` if it was created
   before, or the `docker run` in the plugin's README if it never was.
3. Keep working without it, and note what you would have stored so it can be written later.

Nothing you call through the tools can bring the service back.

## "Needs authentication" / 401

The connection is protected by OAuth. The person signs in once in the browser as the owner the
container was started with:

- **Claude Code**: `/mcp` → `tessaridb-am` → *Authenticate*.
- **Codex**: `codex mcp login tessaridb-am`.

The browser comes back to a local port, which must be free while signing in. A token that expires
is renewed by the client. If sign-in keeps failing, tell the person rather than retrying.

## Refused before anything happened: no session

Every tool except `session_start` is refused until a session exists. After a context compaction or
a client restart, call `session_start` again. To the service you are a new session.

## Refused: the folder is not declared

`session_start` names the folder and asks for a declaration. Ask the person whether the folder is
one project, or a group whose subfolders are projects (and which ones). Then call `session_start`
again with `declare`. Don't guess: the declaration decides where every later record lands.

## Refused: version mismatch on `item_update`

Someone changed the item after you read it. Read it again (for example with `recall`), apply your
change to what it now says, and send that with the new version. Never retry with the old version.

## Refused: a lifecycle move

The refusal lists the moves allowed from the item's current state. Pick one of those, or move
through an intermediate state.

## Refused: a task is held

The answer names the holding session and when its hold ends. Do something else, or ask the person
whether to wait.

## Empty answer from `recall`

Check the scope first: by default only your exact project is read. Then try other words, fewer
words, or a topic filter. Only then conclude nothing is there.

## A credential leaked, or a person must be locked out

There is deliberately no tool for this. Adding users, blocking them and granting or withdrawing
authority are operator acts on the command line. If a credential has leaked, tell the person and
name the command:

```
tessari-am admin credential.revoke
```

It stops the credential admitting anyone and ends its logins. `tessari-am --help` lists every
operator command. The person runs it, not you.

## A tool answers that it is not carried out

Some tools are listed but their backing isn't built yet. Their descriptions start with
`[not carried out]`, and they answer by saying so instead of pretending:

| Not built | Use instead |
|---|---|
| `changes_since` | `recall` and `status` |
| `export`, `import` | nothing yet; the store can't be taken out through the tools |
| `status` at widths `group` and `installation` | `status` at widths `me` and `project` |
| paging a ranked search with `page.after` | a narrower query or a larger `page.limit` |

