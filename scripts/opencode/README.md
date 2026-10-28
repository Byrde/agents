# OpenCode

These scripts set up OpenCode 2 in a project. Each practice skill becomes an agent. Each agent runs on the model that suits its kind of work.

## Requirements

- OpenCode 2, `jq`, `python3`, `curl` and `git`.
- An [Artificial Analysis](https://artificialanalysis.ai/) API key in `ARTIFICIAL_ANALYSIS_API_KEY`. The free tier is enough. Without a key, the init uses the last download. If there is no download, the agents use the session's model.
- For Fuel iX, a Fuel iX API key in `FUELIX_API_KEY`.
- For GitHub, the `gh` CLI, logged in with `gh auth login`.

## Set up a project

1. Go to the root of your project.
2. Export the keys:

   ```bash
   export ARTIFICIAL_ANALYSIS_API_KEY=...
   export FUELIX_API_KEY=...
   ```

3. Optional: add Fuel iX models as providers. The script lists the models and asks which ones to add.

   ```bash
   .agents/scripts/opencode/setup-fuelix.sh
   ```

4. Install the agents and score the models:

   ```bash
   .agents/scripts/opencode/init.sh
   ```

5. Restart OpenCode. Press Tab to switch to an agent.

## Commands

| Command | What it does |
|---|---|
| `init.sh` | Installs the agents, the rules and the plugin. Then it scores the models. |
| `init.sh evaluate` | Scores the models again. Run it after you change a provider or its models. |
| `init.sh uninstall` | Removes what `init.sh` wrote. |
| `setup-fuelix.sh` | Adds the Fuel iX providers with the models you choose. If `init.sh` ran before, it then runs `init.sh evaluate`. |
| `setup-fuelix.sh --models a,b,c` | Adds these models, with no question. |
| `setup-fuelix.sh uninstall` | Removes the Fuel iX providers. |

## More information

The [root README](../../README.md#opencode) tells which files the init writes, how the scoring works, and what the plugin does.
