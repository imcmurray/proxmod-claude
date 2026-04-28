# Notice — Origin and License Status

## Upstream

`agentic.sh` in this repository is a derivative work based on the script of the
same name from:

> **[serversathome-personal/code](https://github.com/serversathome-personal/code)**

The original `agentic.sh` provided the deployment skeleton: prompts, `pct create`
invocation, the in-container provisioning heredoc, plugin installs, and Docker
service stacks. Full credit to the upstream author.

## License status of the upstream

At the time of writing, the upstream repository has **no LICENSE file**. Under
default copyright, this means the original author retains all rights and has not
explicitly granted permission to copy, modify, or redistribute. Public visibility
on GitHub grants only the rights provided by GitHub's Terms of Service (viewing
and forking through the GitHub interface) — it is not equivalent to an open-source
license.

We are publishing this fork in good faith, with prominent attribution, and welcome
contact from the upstream author to clarify reuse rights. Specifically:

- If the upstream author wants this fork taken down, please open an issue and we
  will comply.
- If the upstream author wants to add a license to their original repo, that
  would clarify rights for everyone benefiting from this work.
- If the upstream author wants this fork to use a specific license, we are open
  to relicensing.

## What's licensed under MIT in this repo

The MIT license in [`LICENSE`](./LICENSE) covers:

- All documentation files (`README.md`, `claude-code-container-workflow.md`,
  `proxmox-silent-freeze-guide.md`, `NOTICE.md`)
- The **modifications** we made to `agentic.sh` over the upstream version,
  documented in §7 of `README.md`. These include:
  - Two-stage network/DNS readiness checks
  - Provisioning log capture and end-of-run verification
  - Random code-server password generation and display
  - `python-is-python3` package addition
  - Storage default change
  - DNS default change

## What is *not* covered by our MIT license

The portions of `agentic.sh` that remain substantially identical to the upstream
original are subject to the upstream's (currently unspecified) license. If you
intend to redistribute or significantly modify `agentic.sh`, the safest path is
to first obtain explicit permission from the upstream author or wait for them to
add a license to their repository.
