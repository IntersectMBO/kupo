# Testing Strategy

## GitHub Actions checks

Fork pull requests run `nix build --no-link --print-build-logs .#checks.x86_64-linux.kupo-unit` without repository secrets or a live Cardano node. Same-repository pull requests, pushes to `master`, and manual Continuous Integration runs retain the AWS-backed integration tests. Manual runs retain the branch/ref selector; select a trusted repository revision because those runs have AWS access. Repository writers are trusted with that access.

The fork job conditions route checks; GitHub's restrictions on fork tokens and secrets provide the security boundary. Keep those restrictions enabled in repository settings. Container publication requires a successful Continuous Integration run for the exact tagged commit from a push to `master` or a manual run on `master`; a PR check cannot satisfy it. Actions caching is disabled in these workflows; S3 database snapshots and the Nix binary cache remain available.

### Preprod database cache

Integration tests restore the Preprod database from `s3://$AWS_S3_BUCKET/db-preprod` without uploading it. Ogmios may use the same bucket under `db-preview`; the two prefixes stay separate. Network Synchronization is the sole cache writer, scheduled at 06:17 UTC on odd-numbered days of the month, with manual dispatch also available. Scheduled and manual writers are serialized across refs. This concurrency group only coordinates runs in this repository.

The new workflow must first exist on the default branch for scheduling and manual dispatch to be available. After that, manual runs retain the branch/ref selector: select a reviewed repository revision because the workflow has AWS access and updates the shared Preprod cache. The synchronization input is a fraction from 0 to 1 (1 means 100%); zero is accepted. Integration tests retain their existing 99.99% threshold.

Restore downloads immutable data, the two newest ledger snapshots, and volatile data. After a successful restore and clean node shutdown, the writer uploads retained snapshots before pruning obsolete snapshots and mirrors volatile files so they stop accumulating. Partial synchronization progress can be saved, but a missing clean-shutdown marker or a reduced immutable chunk count prevents publication. The writer allows up to 290 minutes for synchronization, leaving time for shutdown and upload within the job limit.

The first successful writer run prunes legacy ledger accumulation. Legacy volatile data is still downloaded in full until a writer mirrors the node's current files. The shared prefix is not an atomic snapshot: readers can overlap uploads, and restores retry transfer failures. Avoid running older CI revisions that still upload the entire database alongside the new writer. If bucket versioning is enabled, lifecycle rules control storage occupied by noncurrent object versions.

The helpers in `.github/workflows/scripts/` also work outside CI. Restore/save require Bash, jq, s5cmd, and appropriately scoped AWS credentials plus the AWS region, loaded in the environment or an AWS profile before invocation. Restore needs list/read access; save also needs upload/delete access under the selected prefix. Never put credential values in command-line arguments. Use a dedicated local database directory, restore before starting the node, stop the node cleanly before saving, and serialize writers yourself outside GitHub Actions.

```bash
nix shell nixpkgs#s5cmd -c \
  ./.github/workflows/scripts/preprod-db-restore.sh "s3://$AWS_S3_BUCKET/db-preprod" /path/to/db-preprod
# After running and cleanly stopping the node:
nix shell nixpkgs#s5cmd -c \
  ./.github/workflows/scripts/preprod-db-save.sh "s3://$AWS_S3_BUCKET/db-preprod" /path/to/db-preprod
```

Run cache and node-sync regression tests with `python3 .github/workflows/scripts/test-preprod-cache.py` (requires Bash and jq). They use local fixtures and fake S3/Docker commands without accessing AWS or starting containers.

## End-to-End

Most of the application logic is tested end-to-end in [KupoSpec](./Test/KupoSpec.hs). This set of tests is only executed if the environment variables `CARDANO_NODE_SOCKET` and `CARDANO_NODE_CONFIG` are set and rightfully point to a Cardano testnet node. The node is assumed to by somewhat already synced (at least, up to epoch 192). 

Various scenarios are tested, including:

- failure recovery when the node isn't up-and-running;
- restarting the application with various combination of options;
- in-memory and on-disk indexing...

To run the Hydra integration tests, make sure the `HYDRA_HOST` and `HYDRA_PORT` are set and point to a running `hydra-node`. The [hydra repository](https://github.com/cardano-scaling/hydra) also provides a tool to start "busy" local devnet quickly using `hydra-cluster --devnet --publish-hydra-scripts --busy`.

## State-Machine

In [AppSpec](./Test/Kupo/AppSpec.hs), Kupo implements a state-machine testing strategy to test the application as a black box (or as _John Hughes_ says 'a big ball of mud'), alongside with a model. These tests focuses on how kupo maintains a consistent database index w.r.t to the UTxO set. They do so by mocking the networking side of Kupo and modelling that as arbitrarily generated events (roll-forward / roll-backward).  This generates a sequence of events which can be interpreted by Kupo and that are interleaved with client requests on the API. The observations on the real application are compared against a simple model (i.e. a linked list of the chain) through post-conditions checked on each query.

On failure, the machinery spits a (somewhat minimal) sequence of events that can lead to a discrepancy between the model and the real world (a.k.a a counter-example). All-in-all, it's a very powerful way to test the ugly parts of the applications.

By default, the state-machine tests only run a few sequences but the number of iterations can be increased using the `KUPO_STATE_MACHINE_ITERATIONS` environment variable.

## Mailbox

The mailbox component (producer/consumer interface) is written using [`io-classes`](https://github.com/input-output-hk/ouroboros-network/tree/master/io-classes) which thereby allows for testing it in simulated IO to look for deadlocks or even, analyze the performance of the pattern: kupo _assumes_ a producer which is much faster than the consumer and [MailboxSpec](./Test/Kupo/App/MailboxSpec.hs) controls that the mailbox patterns performs well with these hypothesis. 

## Http Server

Kupo uses the very idiomatic (in Haskell) [warp](https://hackage.haskell.org/package/warp) and [wai](https://hackage.haskell.org/package/wai) stack for writing the HTTP server. In combination, they allow to decouple the web application logic as pure wai expression and thus, to test it using only pure code. This happens in [HttpSpec](./Test/Kupo/App/HttpSpec.hs). In these tests, the database component is stubbed to produce arbitrary data for every request. More, the test(s) do not only runs requests against a pure Wai application, but they also control that the resulting JSON output abides by Kupo's [OpenAPI specification](../docs/openapi.yaml). Since server outputs are randomly generated, and each test scenario executed hundred of times, this makes for a good coverage of the JSON specification against outputs produced by the server.

## Patterns

Patterns parsing from text and matching are tested through [PatternSpec](./Test/Kupo/PatternSpec.hs) which makes use of pre-defined cases as [Pattern.Fixture](./Test/Kupo/Data/Pattern/Fixture.hs). In the fixtures are define addresses made out of various credentials (scripts, verification key hashes). Then, the test defines a matrix of text patterns  with the addresses they're expected to match. The addresses, credentials and patterns have been chosen to offer a good coverage of the pattern parsing and matching. 

## Database

Types are marshalled to and from the database using specific functions. The [DatabaseSpec](./Test/Kupo/Data/DatabaseSpec.hs) defines roundtrip properties checking that arbitrarily generated data can be marshalled to their database representations, and unmarshalled back to their high-level application form. The module also checks that addresses stored in the database can be fetched correctly via their expected text patterns, translated as SQL(ite) queries. 

## Command-line & configuration

Command-line options are fully tested in [OptionsSpec](./Test/Kupo/OptionsSpec.hs). The test matrix cover various combination of options, testing out few malformed cases as well. [ConfigurationSpec](./Test/Kupo/ConfigurationSpec.hs) controls that well-formed node configurations and genesis files can be parsed, using those served from [cardano-configurations](https://github.com/input-output-hk/cardano-configurations). In addition, [CardanoSpec](./Test/Kupo/Data/CardanoSpec.hs) also checks using basic properties the parsing from text of a few data-types used in the configuration definition (points, slot, header hash...). 
