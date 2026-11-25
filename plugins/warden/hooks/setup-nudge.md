**Setup check for a new repository.** This session created the repository in the command below, and it now has enough code for a code graph.
skill: Run the setup check for it before the first code exploration in this skill:
commit: Run the setup check for it before your next code exploration in that repository. Run it also before you dispatch the next subagent into it, whatever skill is running:

```bash
cd {{REPO}} && {{GRAPHIFY_SETUP}} status
```

Act on the printed word as the Setup check section of the session context says.
