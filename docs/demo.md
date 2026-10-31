# Demo script

This script runs a 10-minute demo of the factory on `keycard-sandbox/keycard-workshop-platform`. A full run takes longer than a demo slot (the judge alone runs `npm ci` and the whole test suite), so you show a finished run and start a live one alongside it.

## Before the demo

1. Pick two small, independent tasks: one file each, with a test the judge can run. Adding a test for an untested pure function works well.
2. Write each one as a task file with `"base_branch": "main"` and the five headings. Give them IDs outside the backlog's range, for example `900-demo-a` and `901-demo-b`.
3. Run the first one ahead of time, through a one-task queue so ntfy fires:

   ```bash
   mkdir -p ~/demo-a && cp 900-demo-a.json ~/demo-a/
   ./factory batch ~/demo-a
   ```

4. Check that it ends with exit 0 and a PR, and don't merge the PR. Note its `run_id`.
5. Subscribe to the ntfy topic on your phone, and make sure no `HALT` file exists.

## During the demo

1. Show the diagram in the README (1 minute), and trace task, worker, judge, push, PR and human.
2. Start the live run (1 minute):

   ```bash
   mkdir -p ~/demo-b && cp 901-demo-b.json ~/demo-b/
   ./factory batch ~/demo-b
   ```

3. Show it working (2 minutes). In a second terminal, run:

   ```bash
   docker ps --filter label=factory.run
   tail -f runs/*-901-demo-b/log.jsonl | jq -r '.event.text // .event.type'
   ```

   Point out that the container runs as non-root on a read-only filesystem, and holds one secret.
4. Show the finished run (4 minutes). Open `runs/<run_id>/manifest.json`, then `judge-1.md`, then the PR on GitHub with the verdict in its body. Point out that the App opened the PR and can't approve it.
5. Walk through the security table in the README (2 minutes), including the Gap rows. The biggest are open egress, credentials inside the containers, and no package admission point.
6. To close, if the live run has finished, show the `done:` notification on your phone. If not, show `./factory report`.
