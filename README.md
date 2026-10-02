# TessariDB Agent Plugins

Plugins that let an agent work with [TessariDB](https://tessaridb.com).

This repository is the **marketplace** and the plugins themselves, for **Claude Code** and for
**Codex**: each plugin carries a manifest for both (`.claude-plugin/` and `.codex-plugin/`) and the
same skills, and each host has its own marketplace file (`.claude-plugin/marketplace.json` and
`.agents/plugins/marketplace.json`). Installing a plugin from here
clones this repository and nothing else: a plugin never drags a product's source tree along behind
it, and that stays true whether the product is public or not.

An entry may also point at another repository when a plugin has reason to live elsewhere; the
section at the end shows both forms.

## What is in it

| Plugin | What it does |
|---|---|
| `tessaridb` | Working with TessariDB itself: a skill covering TessariQL, every engine (full text, vectors, geometry, graphs, key-value, queues, topics, time series, vaults), transactions and history, the five clients, and running a node or a cluster. No server; nothing to start. |
| `tessaridb-agent-memory` | Memory for an agent, stored in TessariDB: registers the memory server and carries a skill that says when to reach for it, which tool fits which job, and how goals, tasks, checklists and releases are tracked. In Claude Code, a hook puts the session's `status` back into the context after every compaction — the memory session lives on the connection and survives it. |

The skills are plain Markdown: a `SKILL.md` that says when to use it and what to read, and a
`references/` folder with the detail. Every TessariQL example in the `tessaridb` skill is run
against the TessariDB release the skill names.

## Install

Add the marketplace, then install what you want from it:

In **Claude Code**:

```shell
/plugin marketplace add tessaridb/tessaridb-agent-plugins
/plugin install tessaridb@tessaridb
/plugin install tessaridb-agent-memory@tessaridb
```

In **Codex**:

```shell
codex plugin marketplace add tessaridb/tessaridb-agent-plugins
codex plugin add tessaridb@tessaridb
codex plugin add tessaridb-agent-memory@tessaridb
```

To keep a local copy current after a plugin is updated:

```shell
/plugin marketplace update
```

In Codex:

```shell
codex plugin marketplace upgrade
codex plugin add tessaridb-agent-memory@tessaridb
```

## For a whole project

Put it in the repository's `.claude/settings.json` and everyone who trusts the folder gets it
without a prompt of their own:

```json
{
  "extraKnownMarketplaces": {
    "tessaridb": {
      "source": {
        "source": "github",
        "repo": "tessaridb/tessaridb-agent-plugins"
      }
    }
  },
  "enabledPlugins": {
    "tessaridb-agent-memory@tessaridb": true
  }
}
```

## Before the memory plugin will work

The plugin registers a memory server; it does not carry one. It connects over HTTP to
`http://127.0.0.1:39142/mcp`, which is where the published container serves it, so that container
has to be running on the machine first.

Choose the first owner's passphrase — it is what you type in the browser when the agent asks to
be authorized — and start the container:

```sh
mkdir -m 700 -p ~/.tessaridb
read -rs "p?Passphrase for the first owner: " && printf '%s\n' "$p" > ~/.tessaridb/owner-passphrase; unset p
chmod 644 ~/.tessaridb/owner-passphrase   # the container reads it; the directory keeps others out
docker run -d --name agent-memory --restart unless-stopped --stop-timeout 30 \
  -p 127.0.0.1:39142:39142 \
  -v tessaridb-agent-memory:/var/lib/tessaridb \
  -v ~/.tessaridb/owner-passphrase:/run/secrets/owner-passphrase:ro \
  -e TESSARI_AM_OWNER=ada -e TESSARI_AM_OWNER_IDENTITY=acme \
  -e TESSARI_AM_OWNER_PASSPHRASE_FILE=/run/secrets/owner-passphrase \
  tessaridb/agent-memory:latest
```

(`read -rs "p?…"` is zsh; in bash it is `read -rsp "…" p`.) The container carries the database
and the memory service together, and the named volume keeps the store across restarts and
upgrades. `--stop-timeout 30` gives `docker stop` the time it needs to close the store cleanly.

Then authorize the client once. In Claude Code, `/mcp` → `tessaridb-am` → **Authenticate**; the
browser returns to `127.0.0.1:39143`. In Codex, `codex mcp login tessaridb-am`; the browser
returns to `127.0.0.1:39144`. Either way you sign in as the owner with the passphrase and approve,
and the port has to be free while you do. Codex needs a memory service from `0.3.0-alpha` on, which knows
the `codex` client.

If the browser lands on a page that will not open after you approve in Codex, the plugin is older
than `0.1.1`: it told Codex where to send you back but not which port to wait on, so Codex waited on
a random one. Update the plugin as above, or sign in once with
`codex -c mcp_oauth_callback_port=39144 mcp login tessaridb-am`.

The address is fixed: the plugin expects port **39142** on the local machine. If the container
publishes a different port, register the server yourself instead of through the plugin:

```sh
claude mcp add --transport http -s user --client-id claude-code --callback-port 39143 \
  tessaridb-am http://127.0.0.1:<port>/mcp
```

A server registered that way and the plugin's own are two entries for the same memory; keep one.

## Installing is not the same as running

The plugin installs from here for anyone, with no access to anything else. What it installs is a
**registration and a skill**, not the memory itself — so until the container is running, the
plugin is present and `/mcp` shows the server as failed to connect, which reads like a plugin
fault and is not one.

That split is deliberate. The memory layer is a separate product with its own repository and its own
licence, and a plugin that carried it would make every install a copy of that product.

## Adding a plugin here

An entry names where the plugin lives rather than copying it in. A subdirectory of another
repository looks like this:

```json
{
  "name": "some-plugin",
  "description": "One sentence a reader can act on.",
  "author": { "name": "boogvar" },
  "category": "productivity",
  "version": "0.1.0",
  "source": {
    "source": "git-subdir",
    "url": "https://github.com/tessaridb/some-repo.git",
    "path": "plugins/some-plugin",
    "ref": "main"
  }
}
```

A whole repository is `"source": "github"` with a `repo`; a directory inside *this* repository is a
plain relative path such as `"./plugins/some-plugin"`. Check the file before pushing:

```shell
/plugin validate .
```

Note that validation answers whether the JSON is well formed. An entry whose source does not resolve
can still validate clean, so a real check is installing it.

## Related

- [TessariDB](https://github.com/tessaridb/tessaridb) — the database
- [Documentation](https://docs.tessaridb.com)
