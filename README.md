# TessariDB Agent Plugins

Plugins that let an agent work with [TessariDB](https://tessaridb.com).

This repository is the **marketplace** and the plugins themselves. Installing a plugin from here
clones this repository and nothing else: a plugin never drags a product's source tree along behind
it, and that stays true whether the product is public or not.

An entry may also point at another repository when a plugin has reason to live elsewhere; the
section at the end shows both forms.

## What is in it

| Plugin | What it does |
|---|---|
| `tessaridb-agent-memory` | Memory for an agent, stored in TessariDB: registers the memory server and carries a skill that says when to reach for it and what a round trip looks like. |

## Install

Add the marketplace, then install what you want from it:

```shell
/plugin marketplace add tessaridb/tessaridb-agent-plugins
/plugin install tessaridb-agent-memory@tessaridb
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

The plugin registers a memory server; it does not carry one. Two things have to be true on the
machine first.

**A node to talk to.** The memory is stored in TessariDB, so a store has to be running and reachable.

**The launcher on `PATH`.** The plugin starts the server by name, as `tessari-am-mcp-run`, so the
command has to be installed and findable. Installing it is part of standing the memory layer up, and
that repository's own instructions cover it.

Without either, the plugin installs cleanly and the server then refuses to start, which reads like a
plugin fault and is not one.

## Installing is not the same as running

The plugin installs from here for anyone, with no access to anything else. What it installs is a
**registration and a skill**, not the memory itself — so until the two things above are true on the
machine, the plugin is present and the server does not come up.

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
