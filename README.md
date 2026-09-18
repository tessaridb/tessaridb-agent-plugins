# TessariDB Agent Plugins

Plugins that let an agent work with [TessariDB](https://tessaridb.com).

This repository is a **marketplace index**. It holds no plugin code of its own — each entry points
at the repository where that plugin actually lives, so a plugin is released on its own schedule and
nothing has to be vendored here to be listed.

## What is in it

| Plugin | What it does | Lives in |
|---|---|---|
| `tessaridb-agent-memory` | Memory for an agent, stored in TessariDB: stands the store and the memory service up locally, registers the memory server, and carries a skill that says when to reach for it. | [`tessaridb-agent-memory`](https://github.com/tessaridb/tessaridb-agent-memory) |

## Install

Add the marketplace, then install what you want from it:

```shell
/plugin marketplace add tessaridb/tessaridb-agent-plugins
/plugin install tessaridb-agent-memory@tessaridb-agent-plugins
```

To keep a local copy current after a plugin is updated:

```shell
/plugin marketplace update
```

## For a whole project

Put it in the repository's `.claude/settings.json` and everyone who trusts the folder gets it
without a prompt of their own:

```json
{
  "extraKnownMarketplaces": {
    "tessaridb-agent-plugins": {
      "source": {
        "source": "github",
        "repo": "tessaridb/tessaridb-agent-plugins"
      }
    }
  },
  "enabledPlugins": {
    "tessaridb-agent-memory@tessaridb-agent-plugins": true
  }
}
```

## Before the memory plugin will work

The plugin registers a memory server; it does not carry one. Two things have to be true on the
machine first.

**A node to talk to.** The memory is stored in TessariDB, so a store has to be running and reachable.

**The launcher on `PATH`.** The plugin starts the server by name, as `tessari-am-mcp-run`, so the
command has to be installed and findable. Installing it is part of standing the memory layer up, and
that repository's own instructions cover it.

Without either, the plugin installs cleanly and the server then refuses to start, which reads like a
plugin fault and is not one.

## Access

`tessaridb-agent-memory` is a private repository, and the entry above pins its `dev` branch. Anyone
installing the plugin needs git access to it; without that, `/plugin install` cannot fetch the
source. That will change when the repository opens.

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
