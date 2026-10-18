# Follow-up after 0.1.0: replace serde_yaml

serde_yaml is archived and unmaintained, and brings in unsafe-libyaml (RUSTSEC-2024-0449, also
unmaintained). For 0.1.0 the owner accepts the advisory in work/deny.toml with a stated reason
(2026-10-17), together with paste (RUSTSEC-2024-0436).

After 0.1.0, a record of its own replaces serde_yaml with a maintained YAML library, chosen then (new
dependency: the owner decides which). What must not change, and what that record's tests hold: every
file farmy reads or writes in YAML (services/<name>.yml, farmy.yml, ports in definitions, tools.yml,
agents.yml, tools.lock, detect/*.yml) parses and round-trips as today, including the comments farmy
writes into definitions (guided add) and the error messages that name a file and a line. The advisory
ignore for RUSTSEC-2024-0449 is removed in the same change.
